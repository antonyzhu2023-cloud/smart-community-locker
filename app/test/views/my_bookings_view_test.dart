import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:scls/models/compartment.dart';
import 'package:scls/models/locker_station.dart';
import 'package:scls/models/reservation.dart';
import 'package:scls/repositories/access_token_repository.dart';
import 'package:scls/repositories/booking_repository.dart';
import 'package:scls/repositories/in_memory_access_backend.dart';
import 'package:scls/repositories/in_memory_auth_repository.dart';
import 'package:scls/repositories/in_memory_booking_repository.dart';
import 'package:scls/repositories/in_memory_locker_repository.dart';
import 'package:scls/viewmodels/auth_view_model.dart';
import 'package:scls/views/my_bookings_view.dart';

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

  Future<Reservation> book(String compartmentId) => bookings.book(
    userId: authVm.user!.id,
    stationId: 'ST-1',
    compartmentId: compartmentId,
    purpose: ReservationPurpose.parcel,
    end: DateTime.now().add(const Duration(hours: 2)),
  );

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<BookingRepository>.value(value: bookings),
          Provider<AccessTokenRepository>.value(value: backend),
          ChangeNotifierProvider<AuthViewModel>.value(value: authVm),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () =>
                      Navigator.of(context).push(MyBookingsView.route()),
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

  testWidgets('shows an empty state before anything is booked', (tester) async {
    await open(tester);
    expect(find.text('No bookings yet'), findsOneWidget);
  });

  testWidgets('lists a booking under Active', (tester) async {
    await book('C1');
    await open(tester);

    expect(find.text('Active'), findsOneWidget);
    expect(find.text('Compartment C1'), findsOneWidget);
    expect(find.text('Confirmed'), findsOneWidget);
  });

  group('cancel', () {
    testWidgets('asks before cancelling', (tester) async {
      await book('C1');
      await open(tester);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Cancel this booking?'), findsOneWidget);
    });

    testWidgets('"Keep it" leaves the booking alone', (tester) async {
      // The failure this guards against is a confirmation dialog wired the
      // wrong way round, which looks correct from the outside and destroys
      // exactly the thing the user tried to protect.
      final booking = await book('C1');
      await open(tester);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keep it'));
      await tester.pumpAndSettle();

      final after = await bookings.fetchBookings(authVm.user!.id);
      expect(after.single.state, ReservationState.confirmed);
      expect(after.single.id, booking.id);
      expect(find.text('Confirmed'), findsOneWidget);
    });

    testWidgets('"Cancel booking" cancels and moves the row to Finished', (
      tester,
    ) async {
      await book('C1');
      await open(tester);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel booking'));
      await tester.pumpAndSettle();

      expect(find.text('Finished'), findsOneWidget);
      expect(find.text('Cancelled'), findsOneWidget);
      expect(find.text('Active'), findsNothing);

      final after = await bookings.fetchBookings(authVm.user!.id);
      expect(after.single.state, ReservationState.cancelled);
    });

    testWidgets('cancelling releases the compartment', (tester) async {
      await book('C1');
      await open(tester);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel booking'));
      await tester.pumpAndSettle();

      expect(
        lockers.compartmentById('ST-1', 'C1')?.state,
        CompartmentState.free,
      );
    });
  });

  group('extend', () {
    testWidgets('extends without asking, because it is reversible', (
      tester,
    ) async {
      final booking = await book('C1');
      await open(tester);

      await tester.tap(find.text('Extend 2 h'));
      await tester.pumpAndSettle();

      final after = await bookings.fetchBookings(authVm.user!.id);
      expect(
        after.single.endTime,
        booking.endTime.add(const Duration(hours: 2)),
      );
    });

    testWidgets('a refused extension shows a dismissible message', (
      tester,
    ) async {
      final booking = await bookings.book(
        userId: authVm.user!.id,
        stationId: 'ST-1',
        compartmentId: 'C1',
        purpose: ReservationPurpose.storage,
        end: DateTime.now().add(const Duration(hours: 71)),
      );
      await open(tester);

      // 71 hours plus 2 is past the 72 hour maximum stay.
      await tester.tap(find.text('Extend 2 h'));
      await tester.pumpAndSettle();

      expect(find.textContaining('72 hours'), findsOneWidget);

      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pumpAndSettle();
      expect(find.textContaining('72 hours'), findsNothing);

      final after = await bookings.fetchBookings(authVm.user!.id);
      expect(after.single.endTime, booking.endTime);
    });
  });

  group('wording', () {
    testWidgets('a live booking is described by when it runs out', (
      tester,
    ) async {
      await book('C1');
      await open(tester);

      expect(find.textContaining('Until '), findsOneWidget);
    });

    testWidgets('a cancelled booking does not claim to have ended', (
      tester,
    ) async {
      // Found by looking at a demo screenshot: the row read "Ended <time>" for
      // a booking that was cancelled hours before that time. The data was
      // right and the sentence was not. No assertion on state or grouping can
      // catch this, because both were already correct.
      final booking = await book('C1');
      await bookings.cancel(booking.id);
      await open(tester);

      expect(find.textContaining('Ended'), findsNothing);
      expect(find.textContaining('Was booked until'), findsOneWidget);
    });
  });

  testWidgets('finished bookings have no cancel or extend buttons', (
    tester,
  ) async {
    final booking = await book('C1');
    await bookings.cancel(booking.id);
    await open(tester);

    expect(find.text('Finished'), findsOneWidget);
    expect(find.text('Cancel'), findsNothing);
    expect(find.text('Extend 2 h'), findsNothing);
  });
}
