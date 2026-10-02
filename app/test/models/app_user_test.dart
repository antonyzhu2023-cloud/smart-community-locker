import 'package:flutter_test/flutter_test.dart';
import 'package:scls/models/app_user.dart';

/// Evaluation criterion E1 requires that an unverified account cannot book.
/// [AppUser.isEligible] is the client-side half of that rule, repeated in the
/// Firestore security rules so it cannot be bypassed.
void main() {
  AppUser build({String? membershipRef, bool verified = false}) => AppUser(
    id: 'U1',
    displayName: 'Test Resident',
    email: 'resident@example.com',
    membershipRef: membershipRef,
    verified: verified,
  );

  test('a new account is not eligible', () {
    expect(build().isEligible, isFalse);
  });

  test('a verified flag alone is not enough', () {
    // Both halves are needed: an account could be email-verified without being
    // matched to the community membership list.
    expect(build(verified: true).isEligible, isFalse);
  });

  test('a membership reference alone is not enough', () {
    expect(build(membershipRef: 'M-204').isEligible, isFalse);
  });

  test('verified and matched to a membership is eligible', () {
    expect(build(verified: true, membershipRef: 'M-204').isEligible, isTrue);
  });

  test('copyWith completing verification keeps the identity fields', () {
    final pending = build();
    final approved = pending.copyWith(verified: true, membershipRef: 'M-204');

    expect(approved.isEligible, isTrue);
    expect(approved.id, 'U1');
    expect(approved.email, 'resident@example.com');
  });
}
