import '../models/app_user.dart';

/// Account creation, sign-in and community membership verification (FR1).
///
/// The same seam as `LockerRepository`: nothing above this interface knows
/// whether accounts live in Firebase Authentication or in a map held in
/// memory. The ViewModel is tested against a fake, so the auth rules in
/// evaluation criterion E1 are checked without a network or a Firebase project.
///
/// Membership verification is deliberately part of this interface rather than
/// something the app checks afterwards. Milestone 1 made eligibility a property
/// of the account because FR7 hands a booking to *another user*: if an account
/// could reach the booking screen before being matched to the community roll,
/// the hand-over feature would be open to anyone who can register.
abstract class AuthRepository {
  /// The signed-in user, or null. Read synchronously so the root widget can
  /// decide what to show on the first frame without flashing a login screen.
  AppUser? get currentUser;

  /// Emits on every sign-in, sign-out and verification change.
  Stream<AppUser?> authStateChanges();

  /// Creates an account. [membershipCode] is the code printed on a resident's
  /// welcome letter or issued by the building manager; a correct one verifies
  /// the account immediately, and an unknown one still creates the account but
  /// leaves it unverified, so the user can sign in and sort it out later.
  Future<AppUser> register({
    required String email,
    required String password,
    required String displayName,
    String? membershipCode,
  });

  Future<AppUser> signIn({required String email, required String password});

  Future<void> signOut();

  /// Verifies an existing account after the fact. Used when someone registered
  /// without a code.
  Future<AppUser> verifyMembership(String membershipCode);
}

/// Why an auth operation failed, in terms the UI can act on.
///
/// The underlying services report failures as string codes. Mapping them here
/// keeps Firebase types out of the ViewModel and makes the failure cases
/// testable without Firebase.
enum AuthFailure {
  invalidEmail,
  weakPassword,
  emailAlreadyInUse,
  userNotFound,
  wrongPassword,
  unknownMembershipCode,
  membershipCodeAlreadyUsed,
  notSignedIn,
  network,
  unknown,
}

class AuthException implements Exception {
  const AuthException(this.failure, this.message);

  final AuthFailure failure;

  /// Shown to the user as written. Kept free of internal detail, per QR5.
  final String message;

  @override
  String toString() => 'AuthException(${failure.name}): $message';
}
