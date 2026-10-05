import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/app_user.dart';
import '../repositories/auth_repository.dart';

/// Which form the single auth screen is showing.
enum AuthMode { signIn, register }

/// Screen state for sign-in, registration and membership verification (FR1).
///
/// Milestone 1 drew registration and sign-in as separate screens. They were
/// merged into one screen with a toggle during implementation, because QR2 caps
/// booking at four screens and an extra navigation step before the user has
/// even reached the lockers spends one of those for nothing. Reported as a
/// design variation.
class AuthViewModel extends ChangeNotifier {
  AuthViewModel(this._repository) {
    _user = _repository.currentUser;
    _subscription = _repository.authStateChanges().listen((user) {
      _user = user;
      notifyListeners();
    });
  }

  final AuthRepository _repository;
  StreamSubscription<AppUser?>? _subscription;

  AppUser? _user;
  AuthMode _mode = AuthMode.signIn;
  bool _busy = false;
  String? _error;

  AppUser? get user => _user;
  AuthMode get mode => _mode;
  bool get isBusy => _busy;
  String? get error => _error;
  bool get hasError => _error != null;

  bool get isSignedIn => _user != null;

  /// E1: a signed-in but unverified account must not reach the booking flow.
  /// The screens read this rather than testing [AppUser.verified] themselves,
  /// so there is one place to change if the rule changes.
  bool get canBook => _user?.isEligible ?? false;

  /// True when the user is signed in but still waiting on a membership code.
  /// This is a distinct screen state: it is not an error and not success.
  bool get needsMembershipVerification => isSignedIn && !canBook;

  void setMode(AuthMode mode) {
    if (_mode == mode) return;
    _mode = mode;
    _error = null;
    notifyListeners();
  }

  void clearError() {
    if (_error == null) return;
    _error = null;
    notifyListeners();
  }

  /// Runs an auth call, turning any failure into a message the View can show.
  /// Returns true when the call succeeded.
  Future<bool> _run(Future<void> Function() action) async {
    _busy = true;
    _error = null;
    notifyListeners();

    try {
      await action();
      return true;
    } on AuthException catch (e) {
      _error = e.message;
      return false;
    } catch (_) {
      // Nothing internal reaches the screen, per QR5.
      _error = 'Something went wrong. Check your connection and try again.';
      return false;
    } finally {
      // Read the session back synchronously rather than waiting for the
      // stream. Stream delivery is asynchronous, so a caller that awaits this
      // method and then reads [isSignedIn] would otherwise be depending on
      // microtask ordering. The subscription still exists, for changes that
      // originate outside this class.
      _user = _repository.currentUser;
      _busy = false;
      notifyListeners();
    }
  }

  Future<bool> signIn({required String email, required String password}) {
    if (email.trim().isEmpty || password.isEmpty) {
      _error = 'Enter your email and password.';
      notifyListeners();
      return Future.value(false);
    }
    return _run(() => _repository.signIn(email: email, password: password));
  }

  Future<bool> register({
    required String email,
    required String password,
    required String displayName,
    String? membershipCode,
  }) {
    if (displayName.trim().isEmpty) {
      _error = 'Enter your name.';
      notifyListeners();
      return Future.value(false);
    }
    return _run(
      () => _repository.register(
        email: email,
        password: password,
        displayName: displayName,
        membershipCode: membershipCode,
      ),
    );
  }

  Future<bool> verifyMembership(String membershipCode) {
    if (membershipCode.trim().isEmpty) {
      _error = 'Enter your membership code.';
      notifyListeners();
      return Future.value(false);
    }
    return _run(() => _repository.verifyMembership(membershipCode));
  }

  Future<bool> signOut() => _run(_repository.signOut);

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
