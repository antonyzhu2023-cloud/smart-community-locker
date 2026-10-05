import 'dart:async';

import '../models/app_user.dart';
import 'auth_repository.dart';

/// An [AuthRepository] backed by a map, with a seeded community roll.
///
/// Used for development before the Firebase project is wired up, and as the
/// stand-in in widget tests. It enforces the same rules as the real
/// implementation will, so a test written against this fake stays meaningful
/// after the swap: passwords have a minimum length, an email can only be
/// registered once, and a membership code can only be claimed once.
///
/// Passwords are held in plain text here. That is acceptable only because this
/// class never runs against real accounts; Firebase Authentication handles
/// credentials in the shipped build, which is the whole reason Milestone 1
/// chose it rather than writing password handling by hand.
class InMemoryAuthRepository implements AuthRepository {
  InMemoryAuthRepository({Map<String, String>? membershipRoll, this.delay})
    : _roll = membershipRoll ?? Map.of(_seedRoll);

  /// Membership code to the unit it belongs to. One code, one account.
  final Map<String, String> _roll;
  final Set<String> _claimedCodes = {};

  final Map<String, _Account> _accounts = {};
  final _controller = StreamController<AppUser?>.broadcast();

  AppUser? _currentUser;

  /// Lets a test or a demo simulate a slow network.
  final Duration? delay;

  /// Four codes, enough to register the accounts a demo needs and still have
  /// one left to show the "already used" path.
  static const Map<String, String> _seedRoll = {
    'WG-1041': 'WG Building, Unit 10.41',
    'WG-1042': 'WG Building, Unit 10.42',
    'SH-0207': 'Student Hub, Unit 2.07',
    'HM-0115': 'Hostel, Room 115',
  };

  /// The shortest password Firebase Authentication accepts. Checked here so the
  /// rule is the same before and after the swap.
  static const int minPasswordLength = 6;

  @override
  AppUser? get currentUser => _currentUser;

  @override
  Stream<AppUser?> authStateChanges() => _controller.stream;

  Future<void> _wait() async {
    if (delay != null) await Future<void>.delayed(delay!);
  }

  void _setUser(AppUser? user) {
    _currentUser = user;
    _controller.add(user);
  }

  static bool _looksLikeEmail(String value) {
    final trimmed = value.trim();
    final at = trimmed.indexOf('@');
    if (at <= 0 || at == trimmed.length - 1) return false;
    return trimmed.substring(at + 1).contains('.') && !trimmed.contains(' ');
  }

  @override
  Future<AppUser> register({
    required String email,
    required String password,
    required String displayName,
    String? membershipCode,
  }) async {
    await _wait();
    final key = email.trim().toLowerCase();

    if (!_looksLikeEmail(key)) {
      throw const AuthException(
        AuthFailure.invalidEmail,
        'That does not look like an email address.',
      );
    }
    if (password.length < minPasswordLength) {
      throw const AuthException(
        AuthFailure.weakPassword,
        'Use at least $minPasswordLength characters.',
      );
    }
    if (_accounts.containsKey(key)) {
      throw const AuthException(
        AuthFailure.emailAlreadyInUse,
        'An account already exists for that email.',
      );
    }

    // A wrong code does not block registration. The account is created
    // unverified, and E1 stops it from booking until the code is sorted out.
    // Rejecting the whole registration would strand a resident who mistyped
    // one character.
    String? membershipRef;
    if (membershipCode != null && membershipCode.trim().isNotEmpty) {
      membershipRef = _claim(membershipCode);
    }

    final user = AppUser(
      id: 'U${_accounts.length + 1}',
      displayName: displayName.trim(),
      email: key,
      membershipRef: membershipRef,
      verified: membershipRef != null,
    );

    _accounts[key] = _Account(password: password, user: user);
    _setUser(user);
    return user;
  }

  /// Claims a membership code, or throws. Returns the unit it refers to.
  String _claim(String code) {
    final normalised = code.trim().toUpperCase();
    final unit = _roll[normalised];
    if (unit == null) {
      throw const AuthException(
        AuthFailure.unknownMembershipCode,
        'That membership code is not on the community list.',
      );
    }
    if (_claimedCodes.contains(normalised)) {
      throw const AuthException(
        AuthFailure.membershipCodeAlreadyUsed,
        'That membership code has already been used.',
      );
    }
    _claimedCodes.add(normalised);
    return unit;
  }

  @override
  Future<AppUser> signIn({
    required String email,
    required String password,
  }) async {
    await _wait();
    final key = email.trim().toLowerCase();

    final account = _accounts[key];
    if (account == null) {
      throw const AuthException(
        AuthFailure.userNotFound,
        'No account found for that email.',
      );
    }
    if (account.password != password) {
      throw const AuthException(
        AuthFailure.wrongPassword,
        'That password is not correct.',
      );
    }

    _setUser(account.user);
    return account.user;
  }

  @override
  Future<void> signOut() async {
    await _wait();
    _setUser(null);
  }

  @override
  Future<AppUser> verifyMembership(String membershipCode) async {
    await _wait();
    final user = _currentUser;
    if (user == null) {
      throw const AuthException(
        AuthFailure.notSignedIn,
        'Sign in before verifying your membership.',
      );
    }

    final unit = _claim(membershipCode);
    final verified = user.copyWith(membershipRef: unit, verified: true);

    _accounts[user.email] = _accounts[user.email]!.withUser(verified);
    _setUser(verified);
    return verified;
  }

  /// Closes the auth state stream. Called by the provider when the app shuts
  /// down, and by tests in tearDown.
  void dispose() {
    _controller.close();
  }
}

class _Account {
  const _Account({required this.password, required this.user});

  final String password;
  final AppUser user;

  _Account withUser(AppUser updated) =>
      _Account(password: password, user: updated);
}
