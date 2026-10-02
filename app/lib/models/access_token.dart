/// A short-lived credential that opens one compartment once.
///
/// From Milestone 1 (FR4): signed by the server, single use, 120 second life,
/// with a numeric PIN as the offline backup. 120 seconds is long enough to walk
/// from the app to the cabinet and short enough that a photograph of the screen
/// is useless.
///
/// One booking can hold several tokens. That is how the hand-over feature (FR7)
/// works: the owner holds one and the person receiving the item holds another,
/// and either can be revoked on its own.
///
/// The client never decides whether a token is valid. [isValid] exists so the
/// UI can show a countdown and refuse obviously dead tokens without a round
/// trip; the server checks the signature and the single-use flag again before
/// it publishes an open command.
library;

class AccessToken {
  const AccessToken({
    required this.id,
    required this.reservationId,
    required this.signedPayload,
    required this.issuedAt,
    required this.expiresAt,
    this.singleUse = true,
    this.used = false,
    this.delegatedTo,
    this.fallbackPin,
  });

  /// The standard life of a token. FR4.
  static const Duration timeToLive = Duration(seconds: 120);

  final String id;
  final String reservationId;

  /// The signed blob that goes into the QR code. The app treats it as opaque.
  final String signedPayload;

  final DateTime issuedAt;
  final DateTime expiresAt;
  final bool singleUse;
  final bool used;

  /// Set when this token was handed to another user (FR7). Null for the
  /// booking owner's own token.
  final String? delegatedTo;

  /// Offline backup. The cabinet keeps only a salted hash of this, and only
  /// while the booking is active (QR4).
  final String? fallbackPin;

  bool get isDelegated => delegatedTo != null;

  bool hasExpired(DateTime now) => !now.isBefore(expiresAt);

  /// A client-side pre-check, not an authorisation decision.
  bool isValid(DateTime now) {
    if (used && singleUse) return false;
    return !hasExpired(now);
  }

  /// Drives the countdown on the access screen.
  Duration remaining(DateTime now) {
    final left = expiresAt.difference(now);
    return left.isNegative ? Duration.zero : left;
  }

  AccessToken copyWith({bool? used, String? delegatedTo}) {
    return AccessToken(
      id: id,
      reservationId: reservationId,
      signedPayload: signedPayload,
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      singleUse: singleUse,
      used: used ?? this.used,
      delegatedTo: delegatedTo ?? this.delegatedTo,
      fallbackPin: fallbackPin,
    );
  }

  @override
  String toString() =>
      'AccessToken($id, expires=$expiresAt, used=$used, delegated=$isDelegated)';
}
