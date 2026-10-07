import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/access_token.dart';
import '../models/reservation.dart';

/// The rules that decide whether a presented credential opens a locker.
///
/// FR4 and FR5, and the whole of evaluation criterion E4. Written as a pure
/// class with no IO so that every refusal can be tested directly: the four
/// cases E4 names are four calls to [decide].
///
/// ### Where this really runs
///
/// In the shipped system this logic belongs to the server, and the server is a
/// Firebase Cloud Function written in TypeScript. This Dart copy is what the
/// in-memory gateway uses, so the app can be developed and demonstrated without
/// a deployed backend.
///
/// That means the rule set exists twice, in two languages. The duplication is a
/// real cost and it is a direct consequence of the stack Milestone 1 chose: a
/// Dart app and a TypeScript backend cannot share a module. It is managed by
/// keeping the rules in this one class on each side and testing both against
/// the same table of cases, not by hoping they stay in step. Reported in
/// section 3.1 as a consequence of the technology decision rather than an
/// oversight.
///
/// ### Why the locker does not run this
///
/// Milestone 1 is explicit that the cabinet never validates a code. It
/// publishes what it scanned and waits. A cabinet that could decide for itself
/// would need the signing key on the device, and a device in a building lobby
/// is the least defensible place to keep one.
class AccessPolicy {
  const AccessPolicy({required this.secret, this.clockSkew = defaultClockSkew});

  /// The signing key. Server-side only. It is passed in rather than read from a
  /// constant so a test can use its own, and so the real one can come from
  /// configuration rather than the repository.
  final String secret;

  /// Allowance for the difference between the issuing clock and the checking
  /// clock. E4 requires the 120 second life to hold to within 2 seconds, so
  /// this stays small on purpose: a generous skew would quietly extend the
  /// life of every token.
  final Duration clockSkew;

  static const Duration defaultClockSkew = Duration(seconds: 2);

  /// Builds the payload that goes into the QR code.
  ///
  /// The signature covers every field, so changing any of them invalidates it.
  /// That is what makes the "altered payload" case in E4 fail closed rather
  /// than being a check somebody has to remember to write.
  String sign(AccessTokenClaims claims) {
    final body = base64Url.encode(utf8.encode(jsonEncode(claims.toJson())));
    return '$body.${_mac(body)}';
  }

  String _mac(String body) {
    final hmac = Hmac(sha256, utf8.encode(secret));
    return base64Url.encode(hmac.convert(utf8.encode(body)).bytes);
  }

  /// Decides what to do with a presented payload.
  ///
  /// [storedToken] and [reservation] are what the server holds; [payload] is
  /// what arrived from the cabinet. Everything the decision depends on is an
  /// argument, including [now], so there is no hidden state and no clock to
  /// stub.
  AccessDecision decide({
    required String payload,
    required DateTime now,
    AccessToken? storedToken,
    Reservation? reservation,
    String? presentedBy,
  }) {
    final claims = verify(payload);
    if (claims == null) return AccessDecision.invalidSignature;

    // Identity before anything else. A valid signature only proves the server
    // minted this token, not that the person holding it should have it.
    if (storedToken == null) return AccessDecision.unknownToken;
    if (storedToken.id != claims.tokenId) return AccessDecision.unknownToken;

    if (storedToken.used && storedToken.singleUse) {
      return AccessDecision.alreadyUsed;
    }

    // The stored expiry wins over the one in the payload. They should agree,
    // but only one of them is out of the holder's reach.
    if (!now.isBefore(storedToken.expiresAt.add(clockSkew))) {
      return AccessDecision.expired;
    }

    if (reservation == null) return AccessDecision.unknownToken;
    if (reservation.id != storedToken.reservationId) {
      return AccessDecision.unknownToken;
    }

    // The single rule from Milestone 1 that FR4 exists to enforce.
    if (!reservation.canIssueToken) return AccessDecision.bookingNotOpenable;

    if (presentedBy != null &&
        !_belongsTo(storedToken, reservation, presentedBy)) {
      return AccessDecision.notYours;
    }

    return AccessDecision.accepted;
  }

  /// A token opens a locker for the person who booked it, or for the one person
  /// it was handed to (FR7). Nobody else, including other verified residents.
  bool _belongsTo(AccessToken token, Reservation reservation, String userId) {
    if (token.isDelegated) return token.delegatedTo == userId;
    return reservation.userId == userId;
  }

  /// Returns the claims if the signature is intact, or null.
  ///
  /// Constant-time comparison, so a caller cannot learn the correct signature
  /// one byte at a time by measuring how long a rejection takes.
  AccessTokenClaims? verify(String payload) {
    final dot = payload.lastIndexOf('.');
    if (dot <= 0 || dot == payload.length - 1) return null;

    final body = payload.substring(0, dot);
    final signature = payload.substring(dot + 1);
    if (!_constantTimeEquals(signature, _mac(body))) return null;

    try {
      final json = jsonDecode(utf8.decode(base64Url.decode(body)));
      if (json is! Map<String, dynamic>) return null;
      return AccessTokenClaims.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}

/// What the signed payload carries. Small on purpose: a QR code on a phone
/// screen in a dim lobby is easier to scan when it holds less.
class AccessTokenClaims {
  const AccessTokenClaims({
    required this.tokenId,
    required this.reservationId,
    required this.stationId,
    required this.compartmentId,
    required this.issuedAt,
    required this.expiresAt,
  });

  final String tokenId;
  final String reservationId;
  final String stationId;
  final String compartmentId;
  final DateTime issuedAt;
  final DateTime expiresAt;

  Map<String, dynamic> toJson() => {
    'tid': tokenId,
    'rid': reservationId,
    'sid': stationId,
    'cid': compartmentId,
    'iat': issuedAt.toUtc().millisecondsSinceEpoch,
    'exp': expiresAt.toUtc().millisecondsSinceEpoch,
  };

  static AccessTokenClaims fromJson(Map<String, dynamic> json) {
    return AccessTokenClaims(
      tokenId: json['tid'] as String,
      reservationId: json['rid'] as String,
      stationId: json['sid'] as String,
      compartmentId: json['cid'] as String,
      issuedAt: DateTime.fromMillisecondsSinceEpoch(
        json['iat'] as int,
        isUtc: true,
      ),
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        json['exp'] as int,
        isUtc: true,
      ),
    );
  }
}

/// The server's answer. Every value other than [accepted] is a refusal that
/// gets logged, which is the second half of E4.
enum AccessDecision {
  accepted,
  expired,
  alreadyUsed,
  invalidSignature,
  unknownToken,
  bookingNotOpenable,
  notYours,
}

extension AccessDecisionMessage on AccessDecision {
  /// What the user is told. Deliberately vague about *why* a credential failed,
  /// beyond what helps a legitimate user act: telling someone holding a
  /// forgery which check it tripped is free help for the next attempt.
  String get userMessage => switch (this) {
    AccessDecision.accepted => 'Opening the locker.',
    AccessDecision.expired => 'That code has expired. Get a new one.',
    AccessDecision.alreadyUsed => 'That code has already been used.',
    AccessDecision.bookingNotOpenable =>
      'That booking is no longer active, so it cannot open a locker.',
    AccessDecision.invalidSignature ||
    AccessDecision.unknownToken ||
    AccessDecision.notYours => 'That code was not accepted.',
  };
}
