import 'package:flutter_test/flutter_test.dart';
import 'package:scls/repositories/in_memory_auth_repository.dart';
import 'package:scls/viewmodels/auth_view_model.dart';

/// Built straight on top of the in-memory repository rather than a mock,
/// because what matters here is the screen state the ViewModel exposes, and the
/// real rules are the ones that produce it.
void main() {
  late InMemoryAuthRepository repo;
  late AuthViewModel vm;

  setUp(() {
    repo = InMemoryAuthRepository();
    vm = AuthViewModel(repo);
  });

  tearDown(() {
    vm.dispose();
    repo.dispose();
  });

  Future<bool> registerVerified() => vm.register(
    email: 'resident@example.com',
    password: 'locker123',
    displayName: 'Test Resident',
    membershipCode: 'WG-1041',
  );

  group('initial state', () {
    test('starts signed out, idle and without an error', () {
      expect(vm.isSignedIn, isFalse);
      expect(vm.isBusy, isFalse);
      expect(vm.hasError, isFalse);
      expect(vm.mode, AuthMode.signIn);
    });

    test('cannot book while signed out', () {
      expect(vm.canBook, isFalse);
    });

    test('does not ask for verification while signed out', () {
      // Otherwise the root widget would show the verification screen to a
      // visitor who has not even registered.
      expect(vm.needsMembershipVerification, isFalse);
    });
  });

  group('register', () {
    test('a verified account can book', () async {
      expect(await registerVerified(), isTrue);

      expect(vm.isSignedIn, isTrue);
      expect(vm.canBook, isTrue);
      expect(vm.needsMembershipVerification, isFalse);
      expect(vm.hasError, isFalse);
    });

    test('an account with no code is signed in but cannot book', () async {
      final ok = await vm.register(
        email: 'visitor@example.com',
        password: 'locker123',
        displayName: 'No Code',
      );

      expect(ok, isTrue);
      expect(vm.isSignedIn, isTrue);
      expect(vm.canBook, isFalse);
      expect(vm.needsMembershipVerification, isTrue);
    });

    test(
      'a bad membership code surfaces as a message, not an exception',
      () async {
        final ok = await vm.register(
          email: 'resident@example.com',
          password: 'locker123',
          displayName: 'Test Resident',
          membershipCode: 'XX-9999',
        );

        expect(ok, isFalse);
        expect(vm.hasError, isTrue);
        expect(vm.error, contains('not on the community list'));
        expect(vm.isSignedIn, isFalse);
      },
    );

    test('an empty name is caught before the repository is called', () async {
      final ok = await vm.register(
        email: 'resident@example.com',
        password: 'locker123',
        displayName: '   ',
      );

      expect(ok, isFalse);
      expect(vm.error, 'Enter your name.');
      // No account was created, so the email is still free.
      expect(await registerVerified(), isTrue);
    });
  });

  group('signIn', () {
    test('restores a verified session', () async {
      await registerVerified();
      await vm.signOut();
      expect(vm.isSignedIn, isFalse);

      final ok = await vm.signIn(
        email: 'resident@example.com',
        password: 'locker123',
      );

      expect(ok, isTrue);
      expect(vm.canBook, isTrue);
    });

    test(
      'a wrong password leaves the user signed out with a message',
      () async {
        await registerVerified();
        await vm.signOut();

        final ok = await vm.signIn(
          email: 'resident@example.com',
          password: 'wrong1',
        );

        expect(ok, isFalse);
        expect(vm.isSignedIn, isFalse);
        expect(vm.error, 'That password is not correct.');
      },
    );

    test('empty fields are caught without touching the repository', () async {
      expect(await vm.signIn(email: '', password: ''), isFalse);
      expect(vm.error, 'Enter your email and password.');
    });

    test('is busy while the call is in flight', () async {
      final slow = InMemoryAuthRepository(
        delay: const Duration(milliseconds: 20),
      );
      final slowVm = AuthViewModel(slow);
      addTearDown(() {
        slowVm.dispose();
        slow.dispose();
      });

      final future = slowVm.register(
        email: 'resident@example.com',
        password: 'locker123',
        displayName: 'Test Resident',
      );
      expect(slowVm.isBusy, isTrue);
      await future;
      expect(slowVm.isBusy, isFalse);
    });
  });

  group('verifyMembership', () {
    test('turns an unverified session into one that can book', () async {
      await vm.register(
        email: 'visitor@example.com',
        password: 'locker123',
        displayName: 'No Code',
      );
      expect(vm.needsMembershipVerification, isTrue);

      final ok = await vm.verifyMembership('SH-0207');

      expect(ok, isTrue);
      expect(vm.canBook, isTrue);
      expect(vm.needsMembershipVerification, isFalse);
    });

    test('an empty code is caught locally', () async {
      await vm.register(
        email: 'visitor@example.com',
        password: 'locker123',
        displayName: 'No Code',
      );

      expect(await vm.verifyMembership('  '), isFalse);
      expect(vm.error, 'Enter your membership code.');
      expect(vm.canBook, isFalse);
    });
  });

  group('signOut', () {
    test('clears the session', () async {
      await registerVerified();
      expect(await vm.signOut(), isTrue);

      expect(vm.isSignedIn, isFalse);
      expect(vm.canBook, isFalse);
      expect(vm.user, isNull);
    });
  });

  group('mode', () {
    test('switching mode clears a stale error', () async {
      await vm.signIn(email: '', password: '');
      expect(vm.hasError, isTrue);

      vm.setMode(AuthMode.register);

      expect(vm.mode, AuthMode.register);
      expect(vm.hasError, isFalse);
    });

    test('setting the same mode does not notify', () async {
      var notifications = 0;
      vm.addListener(() => notifications++);

      vm.setMode(AuthMode.signIn);

      expect(notifications, 0);
    });

    test('clearError is a no-op when there is no error', () {
      var notifications = 0;
      vm.addListener(() => notifications++);

      vm.clearError();

      expect(notifications, 0);
    });

    test('clearError removes a message', () async {
      await vm.signIn(email: '', password: '');
      vm.clearError();
      expect(vm.hasError, isFalse);
    });
  });

  group('notifications', () {
    test('a successful call notifies for busy, state and idle', () async {
      var notifications = 0;
      vm.addListener(() => notifications++);

      await registerVerified();

      // Busy on, the auth-state event from the repository, busy off. The
      // middle one is what drives the root widget to the locker list.
      expect(notifications, greaterThanOrEqualTo(2));
    });
  });
}
