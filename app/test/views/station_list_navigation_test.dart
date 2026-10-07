import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:scls/models/compartment.dart';
import 'package:scls/models/locker_station.dart';
import 'package:scls/repositories/access_token_repository.dart';
import 'package:scls/repositories/booking_repository.dart';
import 'package:scls/repositories/in_memory_access_backend.dart';
import 'package:scls/repositories/in_memory_auth_repository.dart';
import 'package:scls/repositories/in_memory_booking_repository.dart';
import 'package:scls/repositories/in_memory_locker_repository.dart';
import 'package:scls/repositories/locker_repository.dart';
import 'package:scls/viewmodels/auth_view_model.dart';
import 'package:scls/viewmodels/station_list_view_model.dart';
import 'package:scls/views/station_list_view.dart';

/// The journey from the station list into a booking and back.
///
/// Worth testing at this level because the defect it guards against is one the
/// individual screens cannot see: the list showing a free count that the
/// booking just made wrong.
void main() {
  late InMemoryLockerRepository lockers;
  late InMemoryBookingRepository bookings;
  late InMemoryAuthRepository auth;
  late InMemoryAccessBackend backend;
  late AuthViewModel authVm;

  setUp(() async {
    lockers = InMemoryLockerRepository(
      stations: [
        const LockerStation(
          id: 'ST-1',
          name: 'Test Station',
          latitude: -36.85,
          longitude: 174.76,
          status: StationStatus.online,
          compartments: [
            Compartment(
              id: 'C1',
              size: SizeClass.small,
              state: CompartmentState.free,
            ),
            Compartment(
              id: 'C2',
              size: SizeClass.small,
              state: CompartmentState.free,
            ),
          ],
        ),
      ],
    );
    bookings = InMemoryBookingRepository(lockers);
    auth = InMemoryAuthRepository();
    backend = InMemoryAccessBackend(lockers: lockers, bookings: bookings);
    authVm = AuthViewModel(auth);
    await authVm.register(
      email: 'resident@example.com',
      password: 'locker123',
      displayName: 'Test Resident',
      membershipCode: 'WG-1041',
    );
  });

  tearDown(() async {
    authVm.dispose();
    auth.dispose();
    await backend.dispose();
  });

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<LockerRepository>.value(value: lockers),
          Provider<BookingRepository>.value(value: bookings),
          Provider<AccessTokenRepository>.value(value: backend),
          ChangeNotifierProvider<AuthViewModel>.value(value: authVm),
          ChangeNotifierProvider<StationListViewModel>(
            create: (_) => StationListViewModel(lockers),
          ),
        ],
        child: const MaterialApp(home: StationListView()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('tapping a station opens its booking screen', (tester) async {
    await open(tester);

    await tester.tap(find.text('Test Station'));
    await tester.pumpAndSettle();

    expect(find.text('Choose a locker'), findsOneWidget);
  });

  testWidgets('the free count is refreshed after booking', (tester) async {
    await open(tester);
    expect(find.text('2 free of 2'), findsOneWidget);

    await tester.tap(find.text('Test Station'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('C1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Book this locker'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    // Back on the list. Without the reload this would still read "2 free of 2".
    expect(find.text('1 free of 2'), findsOneWidget);
    expect(find.text('2 free of 2'), findsNothing);
  });

  testWidgets('the bookings screen is reachable from the list', (tester) async {
    await open(tester);

    await tester.tap(find.byTooltip('My bookings'));
    await tester.pumpAndSettle();

    expect(find.text('My bookings'), findsOneWidget);
  });
}
