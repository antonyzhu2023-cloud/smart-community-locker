import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../domain/access_policy.dart';
import '../models/access_token.dart';
import '../models/compartment.dart';
import '../models/door_event.dart';
import '../models/reservation.dart';
import 'access_token_repository.dart';
import 'in_memory_booking_repository.dart';
import 'in_memory_locker_repository.dart';
import 'locker_command_gateway.dart';

/// A stand-in for the server and the cabinet, in memory.
///
/// It implements both [AccessTokenRepository] and [LockerCommandGateway]
/// because in the real system both are the server's job: one issues the
/// credential, the other decides whether a presented credential opens a door.
/// Splitting them into two classes here would have meant two copies of the
/// token store.
///
/// ### What is real and what is not
///
/// Real: the signing, the 120 second life, single use, the booking-state rule,
/// ownership including hand-over, the offline PIN path, and the fact that a
/// compartment becomes occupied only after the door closes with something
/// inside.
///
/// Not real: there is no network, no MQTT broker and no cabinet. [present]
/// returns a decision directly instead of publishing to a topic and waiting.
///
/// The authoritative implementation of these rules is the TypeScript Cloud
/// Function. This class exists so the app can be built, demonstrated and tested
/// without a backend running, which is what the Gateway seam in Milestone 1 was
/// for. Both sides are tested against the same case table.
class InMemoryAccessBackend
    implements AccessTokenRepository, LockerCommandGateway {
  InMemoryAccessBackend({
    required this.lockers,
    required this.bookings,
    AccessPolicy? policy,
    this.delay,
    this.doorReportDelay,
    Random? random,
    DateTime Function()? now,
  }) : _policy = policy ?? const AccessPolicy(secret: developmentSecret),
       _random = random ?? Random(),
       _now = now ?? (() => DateTime.now().toUtc());

  /// Used only by this stand-in. The deployed function reads its key from
  /// configuration, and no key of any kind is shipped in the app.
  static const String developmentSecret = 'scls-development-signing-key';

  /// The stores this stand-in reads and writes. Public because it is a
  /// development double, and a test that builds one already holds both.
  final InMemoryLockerRepository lockers;
  final InMemoryBookingRepository bookings;

  final AccessPolicy _policy;
  final Random _random;

  /// Lets a test or a demo simulate a slow link.
  final Duration? delay;

  /// How long the cabinet takes to report what the door did.
  ///
  /// Null means it reports in the same breath as accepting the command, which
  /// no real cabinet does. A delay here is what lets the honest intermediate
  /// state — accepted, but the door has not said anything yet — be observed at
  /// all. FR5 exists because that state is real.
  final Duration? doorReportDelay;

  /// The clock. Injected so the 120 second life in FR4 can be tested without
  /// waiting 120 seconds, and so a caller that also fakes its clock does not
  /// end up disagreeing with this one about what time it is.
  final DateTime Function() _now;

  final Map<String, AccessToken> _tokens = {};

  /// Salted hashes of the backup PINs, by reservation. The cabinet caches these
  /// so QR4's offline path can work with no network at all. The PIN itself is
  /// never stored, here or on the device.
  final Map<String, String> _pinHashes = {};

  final Map<String, StreamController<DoorEvent>> _doorStreams = {};
  final _connection = StreamController<bool>.broadcast();

  bool _connected = true;
  var _nextTokenNumber = 1;

  /// Token ids the cabinet has already acted on.
  ///
  /// MQTT QoS 1 is at-least-once, so the same open command can arrive twice.
  /// Milestone 1 put the fix in the firmware: remember the token id and ignore
  /// a repeat. Kept here so the behaviour exists end to end before there is any
  /// firmware to put it in.
  final Set<String> _actedOn = {};

  @override
  bool get isConnected => _connected;

  @override
  Stream<bool> connectionChanges() => _connection.stream;

  /// Simulates the network going away, for the QR4 offline path.
  void setConnected(bool connected) {
    if (_connected == connected) return;
    _connected = connected;
    _connection.add(connected);
  }

  Future<void> _wait() async {
    if (delay != null) await Future<void>.delayed(delay!);
  }

  // -------------------------------------------------------------------
  // AccessTokenRepository
  // -------------------------------------------------------------------

  @override
  Future<AccessToken> issue({
    required String reservationId,
    required String userId,
  }) => _mint(reservationId: reservationId, userId: userId);

  // `async` on purpose. Without it the guard below throws synchronously, before
  // a Future exists, so a caller that expected a failed Future gets an
  // exception thrown at the call site instead. Caught by a test that could not
  // assert on the rejection it was written to check.
  @override
  Future<AccessToken> issueDelegated({
    required String reservationId,
    required String userId,
    required String delegateUserId,
  }) async {
    if (delegateUserId == userId) {
      throw const TokenException(
        TokenFailure.delegateIsOwner,
        'You already have access to this locker.',
      );
    }
    return _mint(
      reservationId: reservationId,
      userId: userId,
      delegateUserId: delegateUserId,
    );
  }

  Future<AccessToken> _mint({
    required String reservationId,
    required String userId,
    String? delegateUserId,
  }) async {
    await _wait();

    final booking = bookings.reservationById(reservationId);
    if (booking == null) {
      throw const TokenException(
        TokenFailure.notFound,
        'That booking no longer exists.',
      );
    }
    if (booking.userId != userId) {
      throw const TokenException(
        TokenFailure.notYours,
        'That booking belongs to someone else.',
      );
    }
    // The one rule Milestone 1 said the server checks for FR4.
    if (!booking.canIssueToken) {
      throw const TokenException(
        TokenFailure.bookingNotOpenable,
        'That booking is no longer active, so no code can be issued.',
      );
    }

    final now = _now();
    final id = 'TK${_nextTokenNumber++}';
    final claims = AccessTokenClaims(
      tokenId: id,
      reservationId: booking.id,
      stationId: booking.stationId,
      compartmentId: booking.compartmentId,
      issuedAt: now,
      expiresAt: now.add(AccessToken.timeToLive),
    );

    // The backup PIN belongs to the booking, not to the token: it has to keep
    // working when the network is down and no new token can be fetched. So it
    // is created once per booking and reused by every token for that booking.
    if (!_pinHashes.containsKey(booking.id)) {
      final fresh = _newPin();
      _issuedPins[booking.id] = fresh;
      _pinHashes[booking.id] = _hashPin(booking.id, fresh);
    }

    final token = AccessToken(
      id: id,
      reservationId: booking.id,
      signedPayload: _policy.sign(claims),
      issuedAt: now,
      expiresAt: claims.expiresAt,
      delegatedTo: delegateUserId,
      fallbackPin: _issuedPins[booking.id],
    );

    _tokens[id] = token;
    return token;
  }

  /// The plain PINs, kept only so the screen can show the user their own backup
  /// code. The cabinet never receives these, only the hashes.
  final Map<String, String> _issuedPins = {};

  String _newPin() => List.generate(4, (_) => _random.nextInt(10)).join();

  String _hashPin(String reservationId, String pin) {
    final salted = utf8.encode('$reservationId:$pin:$developmentSecret');
    return base64Url.encode(sha256.convert(salted).bytes);
  }

  @override
  Future<void> revoke(String tokenId) async {
    await _wait();
    final token = _tokens[tokenId];
    if (token == null) {
      throw const TokenException(
        TokenFailure.tokenGone,
        'That code has already been withdrawn.',
      );
    }
    // FR7 says a hand-over is revocable *before use*. Removing a spent token
    // would succeed and tell the owner their access had been taken back, when
    // in fact the locker had already been opened. The operation is harmless and
    // the message is not.
    if (token.used) {
      throw const TokenException(
        TokenFailure.tokenGone,
        'That code has already been used, so there is nothing to take back.',
      );
    }
    _tokens.remove(tokenId);
  }

  @override
  Future<List<AccessToken>> tokensFor(String reservationId) async {
    await _wait();
    final mine = _tokens.values
        .where((t) => t.reservationId == reservationId)
        .toList(growable: false);
    return List.unmodifiable(mine);
  }

  @override
  Future<List<AccessToken>> delegationsTo(String userId) async {
    await _wait();
    final mine = _tokens.values
        .where((t) => t.delegatedTo == userId && !t.used)
        .toList(growable: false);
    return List.unmodifiable(mine);
  }

  // -------------------------------------------------------------------
  // LockerCommandGateway
  // -------------------------------------------------------------------

  @override
  Stream<DoorEvent> doorEvents({
    required String stationId,
    required String compartmentId,
  }) => _streamFor(stationId, compartmentId).stream;

  StreamController<DoorEvent> _streamFor(
    String stationId,
    String compartmentId,
  ) {
    return _doorStreams.putIfAbsent(
      '$stationId/$compartmentId',
      () => StreamController<DoorEvent>.broadcast(),
    );
  }

  @override
  Future<OpenOutcome> present({
    required String stationId,
    required String compartmentId,
    String? payload,
    String? pin,
  }) async {
    await _wait();
    final now = _now();

    // QR4. The PIN is checked by the cabinet against a cached hash, so it is
    // the one path that still works with the network down. It is tried first
    // for that reason: offering it only after the online path fails would make
    // the user wait for a timeout every time.
    if (pin != null && pin.isNotEmpty) {
      return _openWithPin(
        stationId: stationId,
        compartmentId: compartmentId,
        pin: pin,
        now: now,
      );
    }

    if (!_connected) {
      return const OpenOutcome(
        decision: OpenDecision.cabinetUnreachable,
        message: 'No connection to the locker. Use your backup PIN.',
      );
    }

    if (payload == null || payload.isEmpty) {
      return const OpenOutcome(
        decision: OpenDecision.unknown,
        message: 'No code was presented.',
      );
    }

    final claims = _policy.verify(payload);
    final stored = claims == null ? null : _tokens[claims.tokenId];
    final booking = stored == null
        ? null
        : bookings.reservationById(stored.reservationId);

    final decision = _policy.decide(
      payload: payload,
      now: now,
      storedToken: stored,
      reservation: booking,
      presentedBy: _presenterOf(stored, booking),
    );

    if (decision != AccessDecision.accepted) {
      // Every refusal is logged. E4 asks for that as well as the refusal.
      _log(
        stationId: stationId,
        compartmentId: compartmentId,
        tokenId: claims?.tokenId,
        decision: decision,
        at: now,
      );
      return OpenOutcome(
        decision: _map(decision),
        message: decision.userMessage,
        tokenId: claims?.tokenId,
        at: now,
      );
    }

    return _accept(
      token: stored!,
      booking: booking!,
      trigger: DoorTrigger.token,
      now: now,
    );
  }

  /// Who is presenting the credential.
  ///
  /// In the real function this comes from the Firebase ID token on the call,
  /// which the holder cannot forge. Here the token itself says who it is for,
  /// because there is no signed-in caller to ask. The ownership rule is still
  /// exercised by the policy tests, which pass the presenter explicitly.
  String? _presenterOf(AccessToken? token, Reservation? booking) {
    if (token == null) return null;
    return token.isDelegated ? token.delegatedTo : booking?.userId;
  }

  Future<OpenOutcome> _openWithPin({
    required String stationId,
    required String compartmentId,
    required String pin,
    required DateTime now,
  }) async {
    // The cabinet holds hashes for the bookings at its own station only, so a
    // PIN is matched against those rather than against every booking.
    for (final entry in _pinHashes.entries) {
      final booking = bookings.reservationById(entry.key);
      if (booking == null) continue;
      if (booking.stationId != stationId) continue;
      if (booking.compartmentId != compartmentId) continue;
      if (_hashPin(entry.key, pin) != entry.value) continue;

      if (!booking.canIssueToken) {
        _log(
          stationId: stationId,
          compartmentId: compartmentId,
          decision: AccessDecision.bookingNotOpenable,
          at: now,
        );
        return OpenOutcome(
          decision: OpenDecision.bookingNotOpenable,
          message: AccessDecision.bookingNotOpenable.userMessage,
          at: now,
        );
      }

      return _accept(
        token: null,
        booking: booking,
        trigger: DoorTrigger.pin,
        now: now,
      );
    }

    _log(
      stationId: stationId,
      compartmentId: compartmentId,
      decision: AccessDecision.invalidSignature,
      at: now,
    );
    return OpenOutcome(
      decision: OpenDecision.wrongPin,
      message: 'That PIN was not accepted.',
      at: now,
    );
  }

  Future<OpenOutcome> _accept({
    required AccessToken? token,
    required Reservation booking,
    required DoorTrigger trigger,
    required DateTime now,
  }) async {
    // Idempotency. A repeated delivery of the same command must not count as a
    // second open.
    if (token != null && _actedOn.contains(token.id)) {
      return OpenOutcome(
        decision: OpenDecision.accepted,
        message: AccessDecision.accepted.userMessage,
        tokenId: token.id,
        at: now,
      );
    }

    if (token != null) {
      _tokens[token.id] = token.copyWith(used: true);
      _actedOn.add(token.id);
    }

    // A booking becomes active at its first successful open, not at its start
    // time, because users arrive late. Milestone 1, booking state machine.
    if (booking.state == ReservationState.confirmed) {
      bookings.replace(booking.copyWith(state: ReservationState.active));
    }

    _emit(
      DoorEvent(
        stationId: booking.stationId,
        compartmentId: booking.compartmentId,
        state: DoorState.open,
        at: now,
        trigger: trigger,
        tokenId: token?.id,
      ),
    );

    _log(
      stationId: booking.stationId,
      compartmentId: booking.compartmentId,
      tokenId: token?.id,
      decision: AccessDecision.accepted,
      at: now,
    );

    return OpenOutcome(
      decision: OpenDecision.accepted,
      message: AccessDecision.accepted.userMessage,
      tokenId: token?.id,
      at: now,
    );
  }

  /// The cabinet reporting that a door was shut.
  ///
  /// Separate from [present] on purpose. A compartment becomes occupied only
  /// when the door closes with something inside, which is a different event at
  /// a different time, and is why Milestone 1 required a door sensor rather
  /// than inferring state from the command.
  void reportDoorClosed({
    required String stationId,
    required String compartmentId,
    required bool itemInside,
  }) {
    final now = _now();

    lockers.setCompartmentState(
      stationId,
      compartmentId,
      itemInside ? CompartmentState.occupied : CompartmentState.reserved,
    );

    _emit(
      DoorEvent(
        stationId: stationId,
        compartmentId: compartmentId,
        state: DoorState.closed,
        at: now,
        trigger: DoorTrigger.userClosed,
        itemInside: itemInside,
      ),
    );
  }

  /// The cabinet reporting that a door was told to open and did not.
  void reportDoorFaulty({
    required String stationId,
    required String compartmentId,
  }) {
    lockers.setCompartmentState(
      stationId,
      compartmentId,
      CompartmentState.outOfService,
    );
    _emit(
      DoorEvent(
        stationId: stationId,
        compartmentId: compartmentId,
        state: DoorState.faulty,
        at: _now(),
      ),
    );
  }

  void _emit(DoorEvent event) {
    // close_sinks cannot follow the lifetime here. The controller is not
    // created by this method; it is owned by _doorStreams and closed in
    // dispose() along with every other one. Suppressed rather than worked
    // around, because restructuring to satisfy the lint would mean giving up
    // the isClosed check below, which is what stops a delayed report arriving
    // after the backend has been torn down.
    // ignore: close_sinks
    final controller = _streamFor(event.stationId, event.compartmentId);
    final reportDelay = doorReportDelay;

    if (reportDelay == null) {
      controller.add(event);
      return;
    }

    // Fire and forget on purpose. The command has been accepted; what the door
    // did arrives later and on its own, which is the whole point of reporting
    // it separately rather than returning it from `present`.
    unawaited(
      Future<void>.delayed(reportDelay, () {
        if (!controller.isClosed) controller.add(event);
      }),
    );
  }

  // -------------------------------------------------------------------
  // Audit log (QR5: every open logged, E4: every refusal logged)
  // -------------------------------------------------------------------

  final List<AccessLogEntry> _entries = [];

  /// Read-only view of what the server recorded. The real system writes this to
  /// Firestore; a test reads it to check that a refusal was not merely refused
  /// but also written down.
  List<AccessLogEntry> get auditLog => List.unmodifiable(_entries);

  void _log({
    required String stationId,
    required String compartmentId,
    required AccessDecision decision,
    required DateTime at,
    String? tokenId,
  }) {
    _entries.add(
      AccessLogEntry(
        stationId: stationId,
        compartmentId: compartmentId,
        tokenId: tokenId,
        decision: decision,
        at: at,
      ),
    );
  }

  static OpenDecision _map(AccessDecision decision) => switch (decision) {
    AccessDecision.accepted => OpenDecision.accepted,
    AccessDecision.expired => OpenDecision.expired,
    AccessDecision.alreadyUsed => OpenDecision.alreadyUsed,
    AccessDecision.invalidSignature => OpenDecision.invalidSignature,
    AccessDecision.unknownToken => OpenDecision.invalidSignature,
    AccessDecision.bookingNotOpenable => OpenDecision.bookingNotOpenable,
    AccessDecision.notYours => OpenDecision.notYours,
  };

  @override
  Future<void> dispose() async {
    for (final controller in _doorStreams.values) {
      await controller.close();
    }
    _doorStreams.clear();
    await _connection.close();
  }
}

/// One line of the audit trail required by QR5.
class AccessLogEntry {
  const AccessLogEntry({
    required this.stationId,
    required this.compartmentId,
    required this.decision,
    required this.at,
    this.tokenId,
  });

  final String stationId;
  final String compartmentId;
  final String? tokenId;
  final AccessDecision decision;
  final DateTime at;

  bool get wasRefused => decision != AccessDecision.accepted;

  /// No payload, no signature and no PIN. A log that contains the credential is
  /// a log that can be replayed from.
  @override
  String toString() =>
      'AccessLogEntry($stationId/$compartmentId, ${decision.name}, '
      'token=$tokenId, at=$at)';
}
