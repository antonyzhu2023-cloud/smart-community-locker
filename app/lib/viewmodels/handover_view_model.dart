import 'package:flutter/foundation.dart';

import '../models/access_token.dart';
import '../models/app_user.dart';
import '../models/reservation.dart';
import '../repositories/access_token_repository.dart';
import '../repositories/auth_repository.dart';

/// Giving one booking to a neighbour (FR7).
///
/// This is the part of the system that no mainstream parcel locker offers, so
/// it is worth being clear about what it actually does. The booking does not
/// change hands. The owner keeps it, and keeps their own access. What the
/// neighbour gets is one token for that booking, which opens the locker once
/// and can be taken back at any time before it is used.
///
/// Two accounts, one booking, two tokens, each revocable on its own. That
/// shape comes straight from the Milestone 1 credential design, where a
/// booking was always allowed to hold several tokens.
class HandoverViewModel extends ChangeNotifier {
  HandoverViewModel({
    required this.tokens,
    required this.auth,
    required this.reservation,
    required this.ownerId,
  });

  final AccessTokenRepository tokens;
  final AuthRepository auth;
  final Reservation reservation;
  final String ownerId;

  List<AccessToken> _outstanding = const [];
  AppUser? _found;
  bool _loading = false;
  bool _working = false;
  String? _error;
  String? _notice;

  List<AccessToken> get outstanding => _outstanding;
  AppUser? get found => _found;
  bool get isLoading => _loading;
  bool get isWorking => _working;
  bool get isBusy => _loading || _working;
  String? get error => _error;
  bool get hasError => _error != null;

  /// A plain confirmation, kept apart from [error] so the screen does not have
  /// to guess which colour to paint a message.
  String? get notice => _notice;

  /// Hand-overs currently live, newest first.
  List<AccessToken> get liveHandovers => _outstanding
      .where((t) => t.isDelegated && !t.used)
      .toList(growable: false);

  bool get hasLiveHandover => liveHandovers.isNotEmpty;

  /// A booking that is finished cannot be given away. The same rule that
  /// governs issuing any token.
  bool get canHandOver => reservation.canIssueToken;

  Future<void> load() async {
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      _outstanding = await tokens.tokensFor(reservation.id);
    } on TokenException catch (e) {
      _error = e.message;
      _outstanding = const [];
    } catch (_) {
      _error = 'Could not load this booking. Check your connection.';
      _outstanding = const [];
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Looks up a neighbour by email before anything is given away.
  ///
  /// A separate step from [handOver] so the owner sees who they are about to
  /// give access to. Handing a locker to a mistyped address is not something a
  /// confirmation dialog can undo.
  Future<bool> findNeighbour(String email) async {
    if (email.trim().isEmpty) {
      _error = 'Enter your neighbour’s email address.';
      _found = null;
      notifyListeners();
      return false;
    }

    _working = true;
    _error = null;
    _notice = null;
    _found = null;
    notifyListeners();

    try {
      final user = await auth.findMember(email);
      if (user == null) {
        // Same message whether the account does not exist or is not verified.
        _error =
            'No verified resident found with that email. They need an account '
            'and a membership code before you can give them a locker.';
        return false;
      }
      if (user.id == ownerId) {
        _error = 'That is your own account. You already have access.';
        return false;
      }
      _found = user;
      return true;
    } on AuthException catch (e) {
      _error = e.message;
      return false;
    } catch (_) {
      _error = 'Could not look that up. Check your connection.';
      return false;
    } finally {
      _working = false;
      notifyListeners();
    }
  }

  void clearNeighbour() {
    if (_found == null) return;
    _found = null;
    _error = null;
    notifyListeners();
  }

  /// Issues the neighbour a token for this booking.
  Future<bool> handOver() async {
    final neighbour = _found;
    if (neighbour == null) {
      _error = 'Find your neighbour first.';
      notifyListeners();
      return false;
    }

    _working = true;
    _error = null;
    _notice = null;
    notifyListeners();

    try {
      await tokens.issueDelegated(
        reservationId: reservation.id,
        userId: ownerId,
        delegateUserId: neighbour.id,
      );
      _outstanding = await tokens.tokensFor(reservation.id);
      _notice = '${neighbour.displayName} can now open this locker once.';
      _found = null;
      return true;
    } on TokenException catch (e) {
      _error = e.message;
      return false;
    } catch (_) {
      _error = 'Could not hand this over. Check your connection.';
      return false;
    } finally {
      _working = false;
      notifyListeners();
    }
  }

  /// Takes a hand-over back. Only works while the token is unused, which is
  /// what FR7 promises.
  Future<bool> takeBack(String tokenId) async {
    _working = true;
    _error = null;
    _notice = null;
    notifyListeners();

    try {
      await tokens.revoke(tokenId);
      _outstanding = await tokens.tokensFor(reservation.id);
      _notice = 'That access has been taken back.';
      return true;
    } on TokenException catch (e) {
      _error = e.message;
      return false;
    } catch (_) {
      _error = 'Could not take that back. Check your connection.';
      return false;
    } finally {
      _working = false;
      notifyListeners();
    }
  }

  void clearMessages() {
    if (_error == null && _notice == null) return;
    _error = null;
    _notice = null;
    notifyListeners();
  }
}
