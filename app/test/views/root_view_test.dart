import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:scls/models/compartment.dart';
import 'package:scls/repositories/in_memory_auth_repository.dart';
import 'package:scls/repositories/locker_repository.dart';
import 'package:scls/viewmodels/auth_view_model.dart';
import 'package:scls/viewmodels/station_list_view_model.dart';
import 'package:scls/views/root_view.dart';

import '../fakes/fake_locker_repository.dart';

/// Evaluation criterion E1 says an unverified account cannot book. These tests
/// check that at the level the user experiences it: whether the locker list can
/// be reached at all. [RootView] chooses the screen from auth state and there is
/// no navigation between the three, so there is no route around the rule.
void main() {
  late InMemoryAuthRepository auth;
  late FakeLockerRepository lockers;
  late AuthViewModel authVm;

  setUp(() {
    auth = InMemoryAuthRepository();
    authVm = AuthViewModel(auth);
    lockers = FakeLockerRepository(
      stations: [
        station('A', compartments: [free('A-s1', SizeClass.small)]),
      ],
    );
  });

  tearDown(() {
    authVm.dispose();
    auth.dispose();
  });

  Widget wrap() {
    return MultiProvider(
      providers: [
        Provider<LockerRepository>.value(value: lockers),
        ChangeNotifierProvider<AuthViewModel>.value(value: authVm),
        ChangeNotifierProvider<StationListViewModel>(
          create: (_) => StationListViewModel(lockers),
        ),
      ],
      child: const MaterialApp(home: RootView()),
    );
  }

  testWidgets('a signed-out visitor sees the sign-in form', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(find.text('Sign in to book a locker.'), findsOneWidget);
    expect(find.text('Nearby lockers'), findsNothing);
  });

  testWidgets('the toggle switches to the registration form', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Create an account'));
    await tester.pumpAndSettle();

    expect(find.text('Create an account for your building.'), findsOneWidget);
    expect(find.text('Full name'), findsOneWidget);
    expect(find.text('Membership code'), findsOneWidget);
  });

  testWidgets('an unverified account is held at the verification screen', (
    tester,
  ) async {
    await authVm.register(
      email: 'visitor@example.com',
      password: 'locker123',
      displayName: 'No Code',
    );

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(find.text('Verify your membership'), findsOneWidget);
    expect(find.text('Nearby lockers'), findsNothing);
  });

  testWidgets('entering a valid code opens the locker list', (tester) async {
    await authVm.register(
      email: 'visitor@example.com',
      password: 'locker123',
      displayName: 'No Code',
    );

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'SH-0207');
    await tester.tap(find.text('Verify'));
    await tester.pumpAndSettle();

    expect(find.text('Nearby lockers'), findsOneWidget);
    expect(find.text('Station A'), findsOneWidget);
  });

  testWidgets('a wrong code keeps the user off the locker list', (
    tester,
  ) async {
    await authVm.register(
      email: 'visitor@example.com',
      password: 'locker123',
      displayName: 'No Code',
    );

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'XX-9999');
    await tester.tap(find.text('Verify'));
    await tester.pumpAndSettle();

    expect(find.text('Verify your membership'), findsOneWidget);
    expect(
      find.text('That membership code is not on the community list.'),
      findsOneWidget,
    );
    expect(find.text('Nearby lockers'), findsNothing);
  });

  testWidgets('a verified account goes straight to the locker list', (
    tester,
  ) async {
    await authVm.register(
      email: 'resident@example.com',
      password: 'locker123',
      displayName: 'Test Resident',
      membershipCode: 'WG-1041',
    );

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(find.text('Nearby lockers'), findsOneWidget);
  });

  testWidgets('signing out returns to the sign-in form', (tester) async {
    await authVm.register(
      email: 'resident@example.com',
      password: 'locker123',
      displayName: 'Test Resident',
      membershipCode: 'WG-1041',
    );

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Sign out'));
    await tester.pumpAndSettle();

    expect(find.text('Sign in to book a locker.'), findsOneWidget);
  });
}
