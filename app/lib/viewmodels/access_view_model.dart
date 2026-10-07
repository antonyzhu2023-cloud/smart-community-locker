import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/access_token.dart';
import '../models/door_event.dart';
import '../models/reservation.dart';
import '../repositories/access_token_repository.dart';
import '../repositories/locker_command_gateway.dart';

/// Screen state for opening a locker (FR4, FR5).
///
/// Three things happen on this screen at once and none of them waits for the
/// others: a token counts down, the user presents it, and the cabinet reports
/// what the door actually did. They are separate pieces of state here for that
/// reason. Collapsing them into one "status" would make it impossible to show
/// the common case honestly — a code that was accepted while the door has not
/// yet reported back.
///
/// The clock is injectable. Without that, every test of the countdown would
/// have to wait in real time, and the 120 second boundary that evaluation
/// criterion E4 cares about could not be checked at all.
class AccessViewModel extends ChangeNotifier {
  AccessViewModel({
    required this.tokens,
    required this.gateway,
    required this.reservation,
    required this.userId,
    Stream<DateTime>? clock,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    _isOnline = gateway.isConnected;

    _connectionSub = gateway.connectionChanges().listen((online) {
      _isOnline = online;
      notifyListeners();
    });

    _doorSub = gateway
        .doorEvents(
          stationId: reservation.stationId,
          compartmentId: reservation.compartmentId,
        )
        .listen((event) {
          _lastDoorEvent = event;
          notifyListeners();
        });

    _clockSub = (clock ?? _everySecond()).listen((_) => _onTick());
  }

  final AccessTokenRepository tokens;
  final LockerCommandGateway gateway;
  final DateTime Function() _now;

  final Reservation reservation;
  final String userId;

  StreamSubscription<bool>? _connectionSub;
  StreamSubscription<DoorEvent>? _doorSub;
  StreamSubscription<DateTime>? _clockSub;

  AccessToken? _token;
  DoorEvent? _lastDoorEvent;
  OpenOutcome? _lastOutcome;

  bool _isOnline = true;
  bool _requesting = false;
  bool _presenting = false;
  bool _pinVisible = false;
  String? _error;

  AccessToken? get token => _token;
  DoorEvent? get lastDoorEvent => _lastDoorEvent;
  OpenOutcome? get lastOutcome => _lastOutcome;

  bool get isOnline => _isOnline;
  bool get isRequesting => _requesting;
  bool get isPresenting => _presenting;
  bool get isBusy => _requesting || _presenting;
  String? get error => _error;
  bool get hasError => _error != null;

  /// The payload to draw as a QR code, or null when there is nothing to show.
  String? get qrPayload => hasLiveToken ? _token!.signedPayload : null;

  /// How long the current token has left. Zero once it is gone.
  Duration get remaining =>
      _token == null ? Duration.zero : _token!.remaining(_now());

  /// A token exists and has not expired. Separate from "a token exists",
  /// because an expired token must stop being displayed rather than sit there
  /// looking scannable.
  bool get hasLiveToken => _token != null && !_token!.hasExpired(_now());

  bool get hasExpiredToken => _token != null && _token!.hasExpired(_now());

  /// A code was presented, accepted, and is therefore spent.
  ///
  /// Distinct from simply having no code. Both leave [hasLiveToken] false, but
  /// they are opposite situations for the user: one is the start of the job and
  /// the other is the end of it. Found by reading a demo screenshot in which
  /// the screen said "Ready when you are, get a code" directly above "The door
  /// is open, opened with your code".
  bool get codeWasUsed => _token == null && (_lastOutcome?.accepted ?? false);

  /// Fraction of the token's life left, for the countdown ring.
  double get remainingFraction {
    if (_token == null) return 0;
    final total = AccessToken.timeToLive.inMilliseconds;
    return (remaining.inMilliseconds / total).clamp(0.0, 1.0);
  }

  /// The backup PIN, shown only when the user asks for it.
  ///
  /// Hidden by default because this screen is held up in a shared lobby. A
  /// 120 second QR code that someone photographs is worthless; a PIN that
  /// someone reads over a shoulder is not, since QR4 makes it reusable for the
  /// life of the booking.
  String? get pin => _pinVisible ? _token?.fallbackPin : null;
  bool get isPinVisible => _pinVisible;
  bool get hasPin => _token?.fallbackPin != null;

  /// True when the cabinet reports the door is open.
  bool get doorIsOpen => _lastDoorEvent?.isOpen ?? false;

  /// True when a code was accepted but the door has not reported yet. This is
  /// the state FR5 exists to make visible: the system asked, and does not yet
  /// know what happened.
  bool get awaitingDoor {
    final outcome = _lastOutcome;
    if (outcome == null || !outcome.accepted) return false;
    final event = _lastDoorEvent;
    if (event == null) return true;
    return event.at.isBefore(outcome.at ?? event.at);
  }

  Stream<DateTime> _everySecond() =>
      Stream<DateTime>.periodic(const Duration(seconds: 1), (_) => _now());

  void _onTick() {
    if (_token == null) return;
    // Only the countdown changes, but it changes every second, so the screen
    // has to be told. Nothing else is recomputed here.
    notifyListeners();
  }

  /// Asks the server for a code (FR4).
  Future<bool> requestToken() async {
    _requesting = true;
    _error = null;
    _lastOutcome = null;
    _pinVisible = false;
    notifyListeners();

    try {
      _token = await tokens.issue(
        reservationId: reservation.id,
        userId: userId,
      );
      return true;
    } on TokenException catch (e) {
      _error = e.message;
      _token = null;
      return false;
    } catch (_) {
      _error = 'Could not get a code. Check your connection and try again.';
      _token = null;
      return false;
    } finally {
      _requesting = false;
      notifyListeners();
    }
  }

  /// Presents the current code without a scanner.
  ///
  /// Milestone 1 chose to build this path first: it needs no camera, runs on
  /// the emulator, and exercises the same server code the cabinet's scanner
  /// reaches over MQTT. The cabinet is the only difference.
  Future<bool> openRemotely() async {
    final token = _token;
    if (token == null) {
      _error = 'Get a code first.';
      notifyListeners();
      return false;
    }
    return _present(payload: token.signedPayload);
  }

  /// The offline path (QR4). Works with no network at all, because the cabinet
  /// checks the PIN against a hash it already holds.
  Future<bool> openWithPin(String pin) async {
    if (pin.trim().isEmpty) {
      _error = 'Enter your backup PIN.';
      notifyListeners();
      return false;
    }
    return _present(pin: pin.trim());
  }

  Future<bool> _present({String? payload, String? pin}) async {
    _presenting = true;
    _error = null;
    notifyListeners();

    try {
      final outcome = await gateway.present(
        stationId: reservation.stationId,
        compartmentId: reservation.compartmentId,
        payload: payload,
        pin: pin,
      );
      _lastOutcome = outcome;

      if (!outcome.accepted) {
        _error = outcome.message;
        // A refused code is spent as far as the screen is concerned. Leaving it
        // on display invites the user to try the same dead code again.
        if (outcome.decision == OpenDecision.alreadyUsed ||
            outcome.decision == OpenDecision.expired) {
          _token = null;
        }
        return false;
      }

      // A single-use code is gone the moment it works.
      if (payload != null) _token = null;
      return true;
    } on GatewayException catch (e) {
      _error = e.message;
      return false;
    } catch (_) {
      _error = 'Could not reach the locker. Try your backup PIN.';
      return false;
    } finally {
      _presenting = false;
      notifyListeners();
    }
  }

  void showPin() {
    if (_pinVisible) return;
    _pinVisible = true;
    notifyListeners();
  }

  void hidePin() {
    if (!_pinVisible) return;
    _pinVisible = false;
    notifyListeners();
  }

  void clearError() {
    if (_error == null) return;
    _error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _connectionSub?.cancel();
    _doorSub?.cancel();
    _clockSub?.cancel();
    super.dispose();
  }
}
