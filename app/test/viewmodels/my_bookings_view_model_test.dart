import 'package:flutter_test/flutter_test.dart';
import 'package:scls/models/compartment.dart';
import 'package:scls/models/locker_station.dart';
import 'package:scls/models/reservation.dart';
import 'package:scls/repositories/in_memory_booking_repository.dart';
import 'package:scls/repositories/in_memory_locker_repository.dart';
import 'package:scls/viewmodels/my_bookings_view_model.dart';

void main() {
  late InMemoryLockerRepository lockers;
  late InMemoryBookingRepository bookings;
  late MyBookingsViewModel vm;

  setUp(() {
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
    vm = MyBookingsViewModel(bookings, 'U1');
  });

  tearDown(() => vm.dispose());

  Future<Reservation> book(String compartmentId, {String userId = 'U1'}) =>
      bookings.book(
        userId: userId,
        stationId: 'ST-1',
        compartmentId: compartmentId,
        purpose: ReservationPurpose.parcel,
        end: DateTime.now().add(const Duration(hours: 2)),
      );

  group('load', () {
    test('starts empty and idle', () {
      expect(vm.bookings, isEmpty);
      expect(vm.isLoading, isFalse);
      expect(vm.hasError, isFalse);
      expect(vm.isEmpty, isTrue);
    });

    test('loads only this user', () async {
      await book('C1');
      await book('C2', userId: 'SOMEONE-ELSE');

      await vm.load();

      expect(vm.bookings, hasLength(1));
      expect(vm.bookings.single.userId, 'U1');
      expect(vm.isEmpty, isFalse);
    });

    test('a user with nothing booked is empty, not an error', () async {
      await vm.load();
      expect(vm.isEmpty, isTrue);
      expect(vm.hasError, isFalse);
    });
  });

  group('active and past', () {
    test('splits live bookings from closed ones', () async {
      final keep = await book('C1');
      final drop = await book('C2');
      await bookings.cancel(drop.id);

      await vm.load();

      expect(vm.active.map((r) => r.id), [keep.id]);
      expect(vm.past.map((r) => r.id), [drop.id]);
    });
  });

  group('cancel', () {
    test('updates the row in place without a reload', () async {
      final booking = await book('C1');
      await vm.load();

      expect(await vm.cancel(booking.id), isTrue);

      expect(vm.bookings.single.state, ReservationState.cancelled);
      expect(vm.active, isEmpty);
      expect(vm.past, hasLength(1));
    });

    test('frees the compartment for someone else', () async {
      final booking = await book('C1');
      await vm.load();
      await vm.cancel(booking.id);

      expect(
        lockers.compartmentById('ST-1', 'C1')?.state,
        CompartmentState.free,
      );
    });

    test('cancelling twice reports a message rather than throwing', () async {
      final booking = await book('C1');
      await vm.load();
      await vm.cancel(booking.id);

      expect(await vm.cancel(booking.id), isFalse);
      expect(vm.error, contains('already been closed'));
    });

    test('other rows are untouched', () async {
      final first = await book('C1');
      final second = await book('C2');
      await vm.load();

      await vm.cancel(first.id);

      final untouched = vm.bookings.firstWhere((r) => r.id == second.id);
      expect(untouched.state, ReservationState.confirmed);
    });
  });

  group('per-row busy state', () {
    test('only the row being changed reports itself busy', () async {
      final slow = InMemoryBookingRepository(
        lockers,
        delay: const Duration(milliseconds: 20),
      );
      final slowVm = MyBookingsViewModel(slow, 'U1');
      addTearDown(slowVm.dispose);

      final first = await slow.book(
        userId: 'U1',
        stationId: 'ST-1',
        compartmentId: 'C1',
        purpose: ReservationPurpose.parcel,
        end: DateTime.now().add(const Duration(hours: 2)),
      );
      final second = await slow.book(
        userId: 'U1',
        stationId: 'ST-1',
        compartmentId: 'C2',
        purpose: ReservationPurpose.parcel,
        end: DateTime.now().add(const Duration(hours: 2)),
      );
      await slowVm.load();

      final future = slowVm.cancel(first.id);

      // A single global "busy" flag would grey out the whole list, which is
      // wrong when only one row is changing.
      expect(slowVm.isWorkingOn(first.id), isTrue);
      expect(slowVm.isWorkingOn(second.id), isFalse);

      await future;
      expect(slowVm.isWorkingOn(first.id), isFalse);
    });

    test('a second change on the same row while busy is ignored', () async {
      final slow = InMemoryBookingRepository(
        lockers,
        delay: const Duration(milliseconds: 20),
      );
      final slowVm = MyBookingsViewModel(slow, 'U1');
      addTearDown(slowVm.dispose);

      final booking = await slow.book(
        userId: 'U1',
        stationId: 'ST-1',
        compartmentId: 'C1',
        purpose: ReservationPurpose.parcel,
        end: DateTime.now().add(const Duration(hours: 2)),
      );
      await slowVm.load();

      final first = slowVm.cancel(booking.id);
      final second = slowVm.cancel(booking.id);

      expect(
        await second,
        isFalse,
        reason: 'a double tap must not double-send',
      );
      expect(await first, isTrue);
    });
  });

  group('extend', () {
    test('adds to the current end time', () async {
      final booking = await book('C1');
      await vm.load();

      expect(await vm.extend(booking.id, const Duration(hours: 2)), isTrue);

      final updated = vm.bookings.single;
      expect(updated.endTime, booking.endTime.add(const Duration(hours: 2)));
      expect(updated.state, ReservationState.confirmed);
    });

    test('is refused past the 72 hour total', () async {
      final booking = await book('C1');
      await vm.load();

      expect(await vm.extend(booking.id, const Duration(hours: 80)), isFalse);
      expect(vm.error, contains('72 hours'));
      expect(vm.bookings.single.endTime, booking.endTime);
    });

    test('a cancelled booking cannot be extended', () async {
      final booking = await book('C1');
      await vm.load();
      await vm.cancel(booking.id);

      expect(await vm.extend(booking.id, const Duration(hours: 1)), isFalse);
      expect(vm.error, contains('no longer be extended'));
    });

    test('an unknown id is reported without calling the repository', () async {
      await vm.load();

      expect(await vm.extend('R999', const Duration(hours: 1)), isFalse);
      expect(vm.error, contains('no longer in your list'));
    });
  });

  group('clearError', () {
    test('removes a message and notifies once', () async {
      final booking = await book('C1');
      await vm.load();
      await vm.cancel(booking.id);
      await vm.cancel(booking.id);
      expect(vm.hasError, isTrue);

      var notifications = 0;
      vm.addListener(() => notifications++);
      vm.clearError();

      expect(vm.hasError, isFalse);
      expect(notifications, 1);
    });

    test('is a no-op when there is no message', () {
      var notifications = 0;
      vm.addListener(() => notifications++);
      vm.clearError();
      expect(notifications, 0);
    });
  });
}
