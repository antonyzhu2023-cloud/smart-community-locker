/// A resident of the community.
///
/// Named [AppUser] rather than `User` to avoid colliding with the Firebase
/// Authentication `User` type once FR1 is wired up.
///
/// Membership verification (FR1) matters because of FR7: a booking is handed to
/// *another user*, so accounts have to be real and checked against the
/// community membership list before anyone can book or receive a hand-over.
class AppUser {
  const AppUser({
    required this.id,
    required this.displayName,
    required this.email,
    this.membershipRef,
    this.verified = false,
  });

  final String id;
  final String displayName;
  final String email;

  /// Reference into the community membership list. Null until verified.
  final String? membershipRef;

  final bool verified;

  /// Only a verified member may book a compartment or receive a hand-over.
  bool get isEligible => verified && membershipRef != null;

  AppUser copyWith({
    String? displayName,
    String? membershipRef,
    bool? verified,
  }) {
    return AppUser(
      id: id,
      displayName: displayName ?? this.displayName,
      email: email,
      membershipRef: membershipRef ?? this.membershipRef,
      verified: verified ?? this.verified,
    );
  }

  @override
  String toString() => 'AppUser($id, $displayName, verified=$verified)';
}
