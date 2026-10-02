import 'package:flutter_test/flutter_test.dart';
import 'package:scls/models/access_token.dart';

/// FR4 says a token lives 120 seconds and may be used once. Evaluation
/// criterion E4 tests the same rules on the server. These tests cover the
/// client-side pre-check only, so the boundaries are checked here where they
/// are cheap to check.
void main() {
  final issued = DateTime(2026, 10, 2, 12, 0, 0);
  final expires = issued.add(AccessToken.timeToLive);

  AccessToken build({
    bool used = false,
    bool singleUse = true,
    String? delegatedTo,
    String? fallbackPin,
  }) {
    return AccessToken(
      id: 'T1',
      reservationId: 'R1',
      signedPayload: 'eyJhbGciOiJF...',
      issuedAt: issued,
      expiresAt: expires,
      singleUse: singleUse,
      used: used,
      delegatedTo: delegatedTo,
      fallbackPin: fallbackPin,
    );
  }

  test('time to live is 120 seconds, as stated in FR4', () {
    expect(AccessToken.timeToLive, const Duration(seconds: 120));
    expect(expires.difference(issued).inSeconds, 120);
  });

  group('hasExpired', () {
    test('is false one second before expiry', () {
      expect(
        build().hasExpired(expires.subtract(const Duration(seconds: 1))),
        isFalse,
      );
    });

    test('is true exactly at expiry', () {
      // The boundary is deliberately closed: at t+120 the token is dead.
      expect(build().hasExpired(expires), isTrue);
    });

    test('is true after expiry', () {
      expect(
        build().hasExpired(expires.add(const Duration(seconds: 1))),
        isTrue,
      );
    });
  });

  group('isValid', () {
    test('a fresh unused token inside its window is valid', () {
      expect(build().isValid(issued.add(const Duration(seconds: 30))), isTrue);
    });

    test('a used single-use token is not valid even inside its window', () {
      expect(
        build(used: true).isValid(issued.add(const Duration(seconds: 30))),
        isFalse,
      );
    });

    test('a used multi-use token stays valid inside its window', () {
      expect(
        build(
          used: true,
          singleUse: false,
        ).isValid(issued.add(const Duration(seconds: 30))),
        isTrue,
      );
    });

    test('an unused token past its window is not valid', () {
      expect(build().isValid(expires), isFalse);
    });
  });

  group('remaining', () {
    test('counts down inside the window', () {
      expect(
        build().remaining(issued.add(const Duration(seconds: 20))),
        const Duration(seconds: 100),
      );
    });

    test('is zero rather than negative after expiry', () {
      expect(
        build().remaining(expires.add(const Duration(minutes: 5))),
        Duration.zero,
      );
    });
  });

  group('delegation (FR7)', () {
    test('the owner token is not delegated', () {
      expect(build().isDelegated, isFalse);
    });

    test('a handed-over token records who it went to', () {
      final t = build(delegatedTo: 'U2');
      expect(t.isDelegated, isTrue);
      expect(t.delegatedTo, 'U2');
    });
  });

  test('copyWith marking a token used does not change anything else', () {
    final original = build(fallbackPin: '4821');
    final used = original.copyWith(used: true);

    expect(used.used, isTrue);
    expect(used.id, original.id);
    expect(used.signedPayload, original.signedPayload);
    expect(used.expiresAt, original.expiresAt);
    expect(used.fallbackPin, '4821');
  });

  test('toString does not leak the signed payload or the PIN', () {
    // A token in a log line must not be replayable. E4 logs every refusal, so
    // this matters in practice.
    final text = build(fallbackPin: '4821').toString();
    expect(text, isNot(contains('eyJhbGciOiJF')));
    expect(text, isNot(contains('4821')));
  });
}
