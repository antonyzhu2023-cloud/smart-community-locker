import 'package:flutter_test/flutter_test.dart';
import 'package:scls/repositories/auth_repository.dart';
import 'package:scls/repositories/in_memory_auth_repository.dart';

/// Evaluation criterion E1: auth flows pass, and an unverified account cannot
/// book. The second half is enforced by `AppUser.isEligible`, which these tests
/// drive through the registration and verification paths that set it.
void main() {
  late InMemoryAuthRepository repo;

  setUp(() => repo = InMemoryAuthRepository());
  tearDown(() => repo.dispose());

  Future<void> registerValid({
    String email = 'resident@example.com',
    String password = 'locker123',
    String? code = 'WG-1041',
  }) async {
    await repo.register(
      email: email,
      password: password,
      displayName: 'Test Resident',
      membershipCode: code,
    );
  }

  group('register', () {
    test(
      'a correct membership code verifies the account immediately',
      () async {
        final user = await repo.register(
          email: 'resident@example.com',
          password: 'locker123',
          displayName: 'Test Resident',
          membershipCode: 'WG-1041',
        );

        expect(user.verified, isTrue);
        expect(user.membershipRef, 'WG Building, Unit 10.41');
        expect(user.isEligible, isTrue);
      },
    );

    test('no code creates an account that cannot book', () async {
      final user = await repo.register(
        email: 'visitor@example.com',
        password: 'locker123',
        displayName: 'No Code',
      );

      expect(user.verified, isFalse);
      expect(user.isEligible, isFalse);
    });

    test('an unknown code is refused and the account is not created', () async {
      await expectLater(
        repo.register(
          email: 'resident@example.com',
          password: 'locker123',
          displayName: 'Test Resident',
          membershipCode: 'XX-9999',
        ),
        throwsA(
          isA<AuthException>().having(
            (e) => e.failure,
            'failure',
            AuthFailure.unknownMembershipCode,
          ),
        ),
      );

      // The email must still be free afterwards, or a typo would lock a
      // resident out of their own address permanently.
      expect(repo.currentUser, isNull);
      await registerValid();
      expect(repo.currentUser?.isEligible, isTrue);
    });

    test('a membership code can only be claimed once', () async {
      await registerValid();
      await repo.signOut();

      await expectLater(
        repo.register(
          email: 'other@example.com',
          password: 'locker123',
          displayName: 'Someone Else',
          membershipCode: 'WG-1041',
        ),
        throwsA(
          isA<AuthException>().having(
            (e) => e.failure,
            'failure',
            AuthFailure.membershipCodeAlreadyUsed,
          ),
        ),
      );
    });

    test('the code is matched case-insensitively and trimmed', () async {
      final user = await repo.register(
        email: 'resident@example.com',
        password: 'locker123',
        displayName: 'Test Resident',
        membershipCode: '  wg-1041 ',
      );
      expect(user.isEligible, isTrue);
    });

    test('a malformed email is refused', () async {
      for (final bad in [
        '',
        'nope',
        'no@domain',
        '@example.com',
        'a b@c.com',
      ]) {
        await expectLater(
          repo.register(email: bad, password: 'locker123', displayName: 'Test'),
          throwsA(
            isA<AuthException>().having(
              (e) => e.failure,
              'failure',
              AuthFailure.invalidEmail,
            ),
          ),
          reason: '"$bad" should not be accepted',
        );
      }
    });

    test('a short password is refused', () async {
      await expectLater(
        repo.register(
          email: 'resident@example.com',
          password: '12345',
          displayName: 'Test',
        ),
        throwsA(
          isA<AuthException>().having(
            (e) => e.failure,
            'failure',
            AuthFailure.weakPassword,
          ),
        ),
      );
    });

    test('the same email cannot be registered twice', () async {
      await registerValid();
      await repo.signOut();

      await expectLater(
        repo.register(
          email: 'RESIDENT@example.com',
          password: 'locker123',
          displayName: 'Impostor',
          membershipCode: 'WG-1042',
        ),
        throwsA(
          isA<AuthException>().having(
            (e) => e.failure,
            'failure',
            AuthFailure.emailAlreadyInUse,
          ),
        ),
      );
    });

    test('registration signs the new user in', () async {
      expect(repo.currentUser, isNull);
      await registerValid();
      expect(repo.currentUser, isNotNull);
    });
  });

  group('signIn', () {
    test('succeeds with the right password', () async {
      await registerValid();
      await repo.signOut();

      final user = await repo.signIn(
        email: 'resident@example.com',
        password: 'locker123',
      );
      expect(user.email, 'resident@example.com');
      expect(repo.currentUser, isNotNull);
    });

    test('the email is not case-sensitive', () async {
      await registerValid();
      await repo.signOut();

      final user = await repo.signIn(
        email: '  Resident@Example.COM ',
        password: 'locker123',
      );
      expect(user.isEligible, isTrue);
    });

    test('a wrong password is refused', () async {
      await registerValid();
      await repo.signOut();

      await expectLater(
        repo.signIn(email: 'resident@example.com', password: 'wrong1'),
        throwsA(
          isA<AuthException>().having(
            (e) => e.failure,
            'failure',
            AuthFailure.wrongPassword,
          ),
        ),
      );
      expect(repo.currentUser, isNull);
    });

    test('an unknown email is refused', () async {
      await expectLater(
        repo.signIn(email: 'nobody@example.com', password: 'locker123'),
        throwsA(
          isA<AuthException>().having(
            (e) => e.failure,
            'failure',
            AuthFailure.userNotFound,
          ),
        ),
      );
    });

    test('a failed sign-in does not disturb an existing session', () async {
      await registerValid();
      final before = repo.currentUser;

      await expectLater(
        repo.signIn(email: 'nobody@example.com', password: 'locker123'),
        throwsA(isA<AuthException>()),
      );

      expect(repo.currentUser, before);
    });
  });

  group('verifyMembership', () {
    test('verifies a signed-in account and keeps its identity', () async {
      final before = await repo.register(
        email: 'visitor@example.com',
        password: 'locker123',
        displayName: 'No Code',
      );
      expect(before.isEligible, isFalse);

      final after = await repo.verifyMembership('SH-0207');

      expect(after.isEligible, isTrue);
      expect(after.membershipRef, 'Student Hub, Unit 2.07');
      expect(after.id, before.id);
      expect(after.email, before.email);
      expect(repo.currentUser?.isEligible, isTrue);
    });

    test('survives a sign-out and sign-in', () async {
      await repo.register(
        email: 'visitor@example.com',
        password: 'locker123',
        displayName: 'No Code',
      );
      await repo.verifyMembership('SH-0207');
      await repo.signOut();

      final user = await repo.signIn(
        email: 'visitor@example.com',
        password: 'locker123',
      );
      expect(user.isEligible, isTrue);
    });

    test('is refused when nobody is signed in', () async {
      await expectLater(
        repo.verifyMembership('WG-1041'),
        throwsA(
          isA<AuthException>().having(
            (e) => e.failure,
            'failure',
            AuthFailure.notSignedIn,
          ),
        ),
      );
    });

    test('an unknown code leaves the account unverified', () async {
      await repo.register(
        email: 'visitor@example.com',
        password: 'locker123',
        displayName: 'No Code',
      );

      await expectLater(
        repo.verifyMembership('XX-9999'),
        throwsA(isA<AuthException>()),
      );
      expect(repo.currentUser?.isEligible, isFalse);
    });
  });

  group('authStateChanges', () {
    test('emits on sign-in and on sign-out', () async {
      final seen = <bool>[];
      final sub = repo.authStateChanges().listen((u) => seen.add(u != null));

      await registerValid();
      await repo.signOut();
      await repo.signIn(email: 'resident@example.com', password: 'locker123');
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(seen, [true, false, true]);
    });
  });

  group('injected roll', () {
    test('a test can supply its own membership codes', () async {
      final custom = InMemoryAuthRepository(
        membershipRoll: const {'TEST-01': 'Test Unit'},
      );
      addTearDown(custom.dispose);

      final user = await custom.register(
        email: 'resident@example.com',
        password: 'locker123',
        displayName: 'Test',
        membershipCode: 'TEST-01',
      );
      expect(user.membershipRef, 'Test Unit');
    });
  });
}
