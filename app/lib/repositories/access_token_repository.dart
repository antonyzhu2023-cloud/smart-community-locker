import '../models/access_token.dart';

/// Asks the server for a credential (FR4).
///
/// The app can only ever *ask*. It cannot mint a token, extend one, or decide
/// that one is valid: those all require the signing key, which lives on the
/// server and nowhere else. This interface is deliberately small for that
/// reason — there is very little the client is allowed to do.
abstract class AccessTokenRepository {
  /// Issues a single-use token for [reservationId], good for 120 seconds.
  ///
  /// Refused unless the booking is confirmed or active, which is the one rule
  /// Milestone 1 said the server checks for FR4.
  Future<AccessToken> issue({
    required String reservationId,
    required String userId,
  });

  /// Issues a token for somebody else to use (FR7).
  ///
  /// A separate token rather than a shared one, so the hand-over can be
  /// revoked without taking the owner's own access away.
  Future<AccessToken> issueDelegated({
    required String reservationId,
    required String userId,
    required String delegateUserId,
  });

  /// Kills a token before it expires. Used to take back a hand-over.
  Future<void> revoke(String tokenId);

  /// Tokens currently outstanding for a booking, so the owner can see who
  /// holds access and withdraw it.
  Future<List<AccessToken>> tokensFor(String reservationId);

  /// Bookings that have been handed to [userId] by somebody else (FR7).
  ///
  /// This is what makes a hand-over visible to the person receiving it. Without
  /// it the feature would only ever be a line of text on the giver's screen,
  /// and the neighbour would have no way to open the locker.
  Future<List<AccessToken>> delegationsTo(String userId);
}

enum TokenFailure {
  /// The booking is cancelled, completed or has expired.
  bookingNotOpenable,

  /// No such booking.
  notFound,

  /// The booking belongs to someone else.
  notYours,

  /// The account is not a verified community member (E1).
  notEligible,

  /// The person being handed the booking is not a verified member either.
  delegateNotEligible,

  /// Cannot hand a booking to yourself.
  delegateIsOwner,

  /// The token has already been revoked or used.
  tokenGone,

  network,
  unknown,
}

class TokenException implements Exception {
  const TokenException(this.failure, this.message);

  final TokenFailure failure;

  /// Shown to the user as written.
  final String message;

  @override
  String toString() => 'TokenException(${failure.name}): $message';
}
