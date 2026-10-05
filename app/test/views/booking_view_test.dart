import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:scls/models/compartment.dart';
import 'package:scls/models/locker_station.dart';
import 'package:scls/models/reservation.dart';
import 'package:scls/repositories/booking_repository.dart';
import 'package:scls/repositories/in_memory_auth_repository.dart';
import 'package:scls/repositories/in_memory_booking_repository.dart';
import 'package:scls/repositories/in_memory_locker_repository.dart';
import 'package:scls/repositories/locker_repository.dart';
import 'package:scls/viewmodels/auth_view_model.dart';
import 'package:scls/views/booking_view.dart';

/// Widget-level checks over the booking screen.
///
/// The ViewModel tests already cover the decisions. What is left here is the
/// wiring that only a widget can get wrong: whether the chips reach the
/// ViewModel, whether the lost-race offer is actually a working button, and
/// whether `BookingView.route` provides what the screen reads.
void main() {
  late InMemoryLockerRepository lockers;
  late InMemoryBookingRepository bookings;
  late InMemoryAuthRepository auth;
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
    authVm = AuthViewModel(auth);
    await authVm.register(
      email: 'resident@example.com',
      password: 'locker123',
      displayName: 'Test Resident',
      membershipCode: 'WG-1041',
    );
  });

  tearDown(() {
    authVm.dispose();
    auth.dispose();
  });

  /// Opens the screen through its own route, so `BookingView.route` is covered
  /// rather than bypassed.
  Future<void> openBooking(WidgetTester tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<LockerRepository>.value(value: lockers),
          Provider<BookingRepository>.value(value: bookings),
          ChangeNotifierProvider<AuthViewModel>.value(value: authVm),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () =>
                      Navigator.of(context).push(BookingView.route('ST-1')),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  Future<void> otherUserTakes(String compartmentId) => bookings.book(
    userId: 'OTHER',
    stationId: 'ST-1',
    compartmentId: compartmentId,
    purpose: ReservationPurpose.parcel,
    end: DateTime.now().add(const Duration(hours: 2)),
  );

  testWidgets('shows the station name and its free compartments', (
    tester,
  ) async {
    await openBooking(tester);

    expect(find.text('Test Station'), findsOneWidget);
    expect(find.textContaining('C1'), findsOneWidget);
    expect(find.textContaining('C2'), findsOneWidget);
  });

  testWidgets('the book button is disabled until a locker is chosen', (
    tester,
  ) async {
    await openBooking(tester);

    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Book this locker'),
    );
    expect(button.onPressed, isNull);

    await tester.tap(find.textContaining('C1'));
    await tester.pumpAndSettle();

    final enabled = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Book this locker'),
    );
    expect(enabled.onPressed, isNotNull);
  });

  testWidgets('booking shows a receipt instead of the form', (tester) async {
    await openBooking(tester);

    await tester.tap(find.textContaining('C1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Book this locker'));
    await tester.pumpAndSettle();

    expect(find.text('Locker booked'), findsOneWidget);
    expect(find.text('Compartment C1'), findsOneWidget);
    expect(
      find.text('Book this locker'),
      findsNothing,
      reason: 'the form must not still be there to submit twice',
    );
  });

  testWidgets('the stay length reaches the booking', (tester) async {
    await openBooking(tester);

    await tester.tap(find.textContaining('C1'));
    await tester.tap(find.text('1 days'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Book this locker'));
    await tester.pumpAndSettle();

    final mine = await bookings.fetchBookings(authVm.user!.id);
    final held = mine.single.endTime.difference(mine.single.startTime);
    expect(held.inHours, closeTo(24, 1));
  });

  testWidgets('the purpose reaches the booking', (tester) async {
    await openBooking(tester);

    await tester.tap(find.textContaining('C1'));
    await tester.tap(find.text('Hand-over'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Book this locker'));
    await tester.pumpAndSettle();

    final mine = await bookings.fetchBookings(authVm.user!.id);
    expect(mine.single.purpose, ReservationPurpose.handover);
  });

  group('losing the race', () {
    testWidgets('offers the alternative as a button', (tester) async {
      await openBooking(tester);
      await tester.tap(find.textContaining('C1'));
      await tester.pumpAndSettle();

      await otherUserTakes('C1');

      await tester.tap(find.text('Book this locker'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Someone just took'), findsOneWidget);
      expect(find.text('Take C2 instead'), findsOneWidget);
    });

    testWidgets('tapping the offer books the alternative', (tester) async {
      await openBooking(tester);
      await tester.tap(find.textContaining('C1'));
      await tester.pumpAndSettle();
      await otherUserTakes('C1');
      await tester.tap(find.text('Book this locker'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Take C2 instead'));
      await tester.pumpAndSettle();

      expect(find.text('Locker booked'), findsOneWidget);
      expect(find.text('Compartment C2'), findsOneWidget);

      final mine = await bookings.fetchBookings(authVm.user!.id);
      expect(mine.single.compartmentId, 'C2');
    });

    testWidgets('no offer appears when nothing is left', (tester) async {
      await openBooking(tester);
      await tester.tap(find.textContaining('C1'));
      await tester.pumpAndSettle();

      await otherUserTakes('C1');
      await otherUserTakes('C2');

      await tester.tap(find.text('Book this locker'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Take'), findsNothing);
    });
  });

  testWidgets('a station with nothing free says so rather than erroring', (
    tester,
  ) async {
    await otherUserTakes('C1');
    await otherUserTakes('C2');

    await openBooking(tester);

    expect(find.text('No lockers free here'), findsOneWidget);
    expect(find.text('Book this locker'), findsNothing);
  });
}
