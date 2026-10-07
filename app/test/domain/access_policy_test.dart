import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:scls/domain/access_policy.dart';
import 'package:scls/models/access_token.dart';
import 'package:scls/models/reservation.dart';

/// Evaluation criterion E4, in full.
///
/// > Replay after expiry, after use, from another account, and with an altered
/// > payload are all four refused and logged. TTL 120 s ±2 s.
///
/// Each of those four is a group below. The policy is a pure class, so the
/// clock is an argument rather than something to stub, and the boundary cases
/// can be checked to the second.
void main() {
  const secret = 'test-signing-key';
  const policy = AccessPolicy(secret: secret);

  final issued = DateTime.utc(2026, 10, 6, 12, 0, 0);
  final expires = issued.add(AccessToken.timeToLive);

  const tokenId = 'T1';
  const reservationId = 'R1';
  const owner = 'U-OWNER';

  AccessTokenClaims claims({
    String id = tokenId,
    String rid = reservationId,
    String sid = 'ST-1',
    String cid = 'C1',
  }) => AccessTokenClaims(
    tokenId: id,
    reservationId: rid,
    stationId: sid,
    compartmentId: cid,
    issuedAt: issued,
    expiresAt: expires,
  );

  AccessToken stored({
    bool used = false,
    bool singleUse = true,
    String? delegatedTo,
    DateTime? expiresAt,
  }) => AccessToken(
    id: tokenId,
    reservationId: reservationId,
    signedPayload: policy.sign(claims()),
    issuedAt: issued,
    expiresAt: expiresAt ?? expires,
    singleUse: singleUse,
    used: used,
    delegatedTo: delegatedTo,
  );

  Reservation booking({
    ReservationState state = ReservationState.confirmed,
    String userId = owner,
  }) => Reservation(
    id: reservationId,
    userId: userId,
    stationId: 'ST-1',
    compartmentId: 'C1',
    purpose: ReservationPurpose.parcel,
    startTime: issued.subtract(const Duration(hours: 1)),
    endTime: issued.add(const Duration(hours: 1)),
    state: state,
  );

  AccessDecision decideWith({
    String? payload,
    DateTime? now,
    AccessToken? token,
    Reservation? reservation,
    String? presentedBy = owner,
  }) => policy.decide(
    payload: payload ?? policy.sign(claims()),
    now: now ?? issued.add(const Duration(seconds: 30)),
    storedToken: token ?? stored(),
    reservation: reservation ?? booking(),
    presentedBy: presentedBy,
  );

  group('the happy path', () {
    test('a fresh token from its owner is accepted', () {
      expect(decideWith(), AccessDecision.accepted);
    });

    test('is accepted while the booking is active, not only confirmed', () {
      // A booking becomes active at the first open. The second open of the same
      // booking must still work, or a user could never retrieve what they put
      // in.
      expect(
        decideWith(reservation: booking(state: ReservationState.active)),
        AccessDecision.accepted,
      );
    });
  });

  group('E4 case 1: replay after expiry', () {
    test('is accepted one second before the deadline', () {
      expect(
        decideWith(now: expires.subtract(const Duration(seconds: 1))),
        AccessDecision.accepted,
      );
    });

    test('is still accepted inside the 2 second skew allowance', () {
      // E4 allows the 120 s life to hold to within 2 s, so the allowance is
      // exactly that and no more.
      expect(
        decideWith(now: expires.add(const Duration(seconds: 1))),
        AccessDecision.accepted,
      );
    });

    test('is refused once the skew allowance is gone', () {
      expect(
        decideWith(now: expires.add(const Duration(seconds: 2))),
        AccessDecision.expired,
      );
    });

    test('is refused long afterwards', () {
      expect(
        decideWith(now: expires.add(const Duration(hours: 6))),
        AccessDecision.expired,
      );
    });

    test('the life of a token is 120 seconds, as FR4 states', () {
      expect(expires.difference(issued), const Duration(seconds: 120));
      expect(AccessToken.timeToLive.inSeconds, 120);
    });

    test('the stored expiry decides, not the one inside the payload', () {
      // Someone who can edit the payload cannot extend their own token, because
      // editing it breaks the signature. But even a correctly signed payload is
      // checked against what the server holds, so the two cannot drift.
      final longLived = claims();
      final serverSaysExpired = stored(
        expiresAt: issued.subtract(const Duration(minutes: 5)),
      );

      expect(
        policy.decide(
          payload: policy.sign(longLived),
          now: issued,
          storedToken: serverSaysExpired,
          reservation: booking(),
          presentedBy: owner,
        ),
        AccessDecision.expired,
      );
    });
  });

  group('E4 case 2: replay after use', () {
    test('a used single-use token is refused', () {
      expect(decideWith(token: stored(used: true)), AccessDecision.alreadyUsed);
    });

    test(
      'used is checked before expiry, so a used token never looks fresh',
      () {
        // Order matters for the audit trail: the log should say the code was
        // reused, not that it was late.
        expect(
          decideWith(
            token: stored(used: true),
            now: expires.add(const Duration(hours: 1)),
          ),
          AccessDecision.alreadyUsed,
        );
      },
    );

    test('a token marked multi-use is not refused for having been used', () {
      expect(
        decideWith(token: stored(used: true, singleUse: false)),
        AccessDecision.accepted,
      );
    });
  });

  group('E4 case 3: another account', () {
    test('a different resident is refused', () {
      expect(
        decideWith(presentedBy: 'U-SOMEONE-ELSE'),
        AccessDecision.notYours,
      );
    });

    test('the person it was handed to is accepted (FR7)', () {
      expect(
        decideWith(
          token: stored(delegatedTo: 'U-NEIGHBOUR'),
          presentedBy: 'U-NEIGHBOUR',
        ),
        AccessDecision.accepted,
      );
    });

    test('once handed over, the owner cannot use that token', () {
      // The delegated token is the neighbour's. The owner keeps their own,
      // which is a different token: one booking, several tokens, each revocable
      // on its own.
      expect(
        decideWith(
          token: stored(delegatedTo: 'U-NEIGHBOUR'),
          presentedBy: owner,
        ),
        AccessDecision.notYours,
      );
    });

    test('a third party cannot use a delegated token either', () {
      expect(
        decideWith(
          token: stored(delegatedTo: 'U-NEIGHBOUR'),
          presentedBy: 'U-STRANGER',
        ),
        AccessDecision.notYours,
      );
    });
  });

  group('E4 case 4: altered payload', () {
    String tamper(String payload, AccessTokenClaims replacement) {
      // Swap the body, keep the original signature. This is the attack the
      // signature exists to stop.
      final body = base64Url.encode(
        utf8.encode(jsonEncode(replacement.toJson())),
      );
      return '$body.${payload.substring(payload.lastIndexOf('.') + 1)}';
    }

    test('a changed compartment is refused', () {
      final original = policy.sign(claims());
      final altered = tamper(original, claims(cid: 'C2'));

      expect(decideWith(payload: altered), AccessDecision.invalidSignature);
    });

    test('a changed station is refused', () {
      final original = policy.sign(claims());
      final altered = tamper(original, claims(sid: 'ST-9'));

      expect(decideWith(payload: altered), AccessDecision.invalidSignature);
    });

    test('a changed token id is refused', () {
      final original = policy.sign(claims());
      final altered = tamper(original, claims(id: 'T-OTHER'));

      expect(decideWith(payload: altered), AccessDecision.invalidSignature);
    });

    test('a changed expiry is refused', () {
      final original = policy.sign(claims());
      final stretched = AccessTokenClaims(
        tokenId: tokenId,
        reservationId: reservationId,
        stationId: 'ST-1',
        compartmentId: 'C1',
        issuedAt: issued,
        expiresAt: issued.add(const Duration(days: 1)),
      );

      expect(
        decideWith(payload: tamper(original, stretched)),
        AccessDecision.invalidSignature,
      );
    });

    test('a payload signed with the wrong key is refused', () {
      const forger = AccessPolicy(secret: 'not-the-real-key');

      expect(
        decideWith(payload: forger.sign(claims())),
        AccessDecision.invalidSignature,
      );
    });

    test('malformed payloads are refused rather than crashing', () {
      for (final junk in [
        '',
        'nodot',
        '.',
        'body.',
        '.signature',
        'not-base64.not-base64',
        '${base64Url.encode(utf8.encode('{"not":"claims"}'))}.x',
      ]) {
        expect(
          decideWith(payload: junk),
          AccessDecision.invalidSignature,
          reason: 'payload "$junk" should be refused',
        );
      }
    });
  });

  group('the booking must still be openable', () {
    test('cancelled, completed and expired bookings are refused', () {
      for (final state in [
        ReservationState.cancelled,
        ReservationState.completed,
        ReservationState.expired,
        ReservationState.requested,
        ReservationState.overdue,
      ]) {
        expect(
          decideWith(reservation: booking(state: state)),
          AccessDecision.bookingNotOpenable,
          reason: 'a $state booking must not open a locker',
        );
      }
    });

    test('exactly two of the seven booking states can open a locker', () {
      var opened = 0;
      for (final state in ReservationState.values) {
        if (decideWith(reservation: booking(state: state)) ==
            AccessDecision.accepted) {
          opened++;
        }
      }
      expect(opened, 2, reason: 'only confirmed and active');
    });
  });

  group('unknown credentials', () {
    // These two call the policy directly rather than through decideWith. The
    // helper fills in a default with `??`, so passing null to it means "use the
    // default" and not "pass null", which is exactly the case under test here.
    test('a token the server has never seen is refused', () {
      expect(
        policy.decide(
          payload: policy.sign(claims()),
          now: issued.add(const Duration(seconds: 30)),
          storedToken: null,
          reservation: booking(),
          presentedBy: owner,
        ),
        AccessDecision.unknownToken,
      );
    });

    test(
      'a payload naming a different token than the stored one is refused',
      () {
        expect(
          decideWith(payload: policy.sign(claims(id: 'T-ELSEWHERE'))),
          AccessDecision.unknownToken,
        );
      },
    );

    test('a token whose booking has vanished is refused', () {
      expect(
        policy.decide(
          payload: policy.sign(claims()),
          now: issued.add(const Duration(seconds: 30)),
          storedToken: stored(),
          reservation: null,
          presentedBy: owner,
        ),
        AccessDecision.unknownToken,
      );
    });

    test('a token pointing at a different booking is refused', () {
      expect(
        decideWith(reservation: booking().copyWith()),
        AccessDecision.accepted,
      );

      final otherBooking = Reservation(
        id: 'R-OTHER',
        userId: owner,
        stationId: 'ST-1',
        compartmentId: 'C1',
        purpose: ReservationPurpose.parcel,
        startTime: issued,
        endTime: issued.add(const Duration(hours: 1)),
        state: ReservationState.confirmed,
      );
      expect(
        decideWith(reservation: otherBooking),
        AccessDecision.unknownToken,
      );
    });
  });

  group('signing and verifying', () {
    test('a signed payload verifies and round-trips its claims', () {
      final original = claims();
      final verified = policy.verify(policy.sign(original));

      expect(verified, isNotNull);
      expect(verified!.tokenId, original.tokenId);
      expect(verified.reservationId, original.reservationId);
      expect(verified.stationId, original.stationId);
      expect(verified.compartmentId, original.compartmentId);
      expect(verified.expiresAt, original.expiresAt);
    });

    test('two different keys produce different signatures', () {
      const other = AccessPolicy(secret: 'another-key');
      expect(policy.sign(claims()), isNot(other.sign(claims())));
    });

    test('the same claims signed twice are identical', () {
      // Deterministic, so a token can be reissued for display without becoming
      // a second credential.
      expect(policy.sign(claims()), policy.sign(claims()));
    });

    test('the payload does not contain the signing key', () {
      expect(policy.sign(claims()), isNot(contains(secret)));
    });
  });

  group('what the user is told', () {
    test('a refusal never says which check it tripped', () {
      // Telling the holder of a forgery that the signature failed, rather than
      // that the code was simply not accepted, is free help for the next
      // attempt.
      for (final decision in [
        AccessDecision.invalidSignature,
        AccessDecision.unknownToken,
        AccessDecision.notYours,
      ]) {
        expect(decision.userMessage, 'That code was not accepted.');
      }
    });

    test('a legitimate user is told enough to act', () {
      expect(AccessDecision.expired.userMessage, contains('Get a new one'));
      expect(
        AccessDecision.alreadyUsed.userMessage,
        contains('already been used'),
      );
    });

    test('every decision has a message', () {
      for (final decision in AccessDecision.values) {
        expect(decision.userMessage, isNotEmpty);
      }
    });
  });
}
