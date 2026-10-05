import 'package:flutter_test/flutter_test.dart';
import 'package:scls/models/compartment.dart';
import 'package:scls/models/locker_station.dart';
import 'package:scls/models/reservation.dart';
import 'package:scls/repositories/in_memory_booking_repository.dart';
import 'package:scls/repositories/in_memory_locker_repository.dart';
import 'package:scls/viewmodels/booking_view_model.dart';

void main() {
  late InMemoryLockerRepository lockers;
  late InMemoryBookingRepository bookings;
  late BookingViewModel vm;

  LockerStation testStation() => const LockerStation(
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
      Compartment(
        id: 'C3',
        size: SizeClass.medium,
        state: CompartmentState.occupied,
      ),
    ],
  );

  setUp(() {
    lockers = InMemoryLockerRepository(stations: [testStation()]);
    bookings = InMemoryBookingRepository(lockers);
    vm = BookingViewModel(bookings, lockers);
  });

  tearDown(() => vm.dispose());

  group('openStation', () {
    test('loads the station and lists only free compartments', () async {
      await vm.openStation('ST-1');

      expect(vm.station?.id, 'ST-1');
      expect(vm.availableCompartments.map((c) => c.id), ['C1', 'C2']);
      expect(vm.isLoading, isFalse);
      expect(vm.hasError, isFalse);
    });

    test('an unknown station is an error, not a crash', () async {
      await vm.openStation('NOPE');

      expect(vm.station, isNull);
      expect(vm.hasError, isTrue);
      expect(vm.error, contains('no longer listed'));
    });

    test('a full station reports itself full rather than failing', () async {
      final full = InMemoryLockerRepository(
        stations: [
          const LockerStation(
            id: 'ST-2',
            name: 'Full',
            latitude: 0,
            longitude: 0,
            status: StationStatus.online,
            compartments: [
              Compartment(
                id: 'X1',
                size: SizeClass.small,
                state: CompartmentState.occupied,
              ),
            ],
          ),
        ],
      );
      final fullVm = BookingViewModel(InMemoryBookingRepository(full), full);
      addTearDown(fullVm.dispose);

      await fullVm.openStation('ST-2');

      expect(fullVm.isFull, isTrue);
      expect(fullVm.hasError, isFalse);
    });

    test('a selection that is no longer free is dropped on refresh', () async {
      await vm.openStation('ST-1');
      vm.selectCompartment(vm.availableCompartments.first);
      expect(vm.selected?.id, 'C1');

      // Someone else takes it between the two loads.
      await bookings.book(
        userId: 'OTHER',
        stationId: 'ST-1',
        compartmentId: 'C1',
        purpose: ReservationPurpose.parcel,
        end: DateTime.now().add(const Duration(hours: 2)),
      );
      await vm.openStation('ST-1');

      // Silently keeping a stale selection would send the user into a booking
      // that is certain to fail.
      expect(vm.selected, isNull);
      expect(vm.canSubmit, isFalse);
    });
  });

  group('selection and options', () {
    test('cannot submit before a compartment is chosen', () async {
      await vm.openStation('ST-1');
      expect(vm.canSubmit, isFalse);

      vm.selectCompartment(vm.availableCompartments.first);
      expect(vm.canSubmit, isTrue);
    });

    test('submitting with nothing chosen says so', () async {
      await vm.openStation('ST-1');

      expect(await vm.submit('U1'), isFalse);
      expect(vm.error, 'Choose a locker first.');
    });

    test('selecting the same compartment twice does not notify', () async {
      await vm.openStation('ST-1');
      final first = vm.availableCompartments.first;
      vm.selectCompartment(first);

      var notifications = 0;
      vm.addListener(() => notifications++);
      vm.selectCompartment(first);

      expect(notifications, 0);
    });

    test('stay defaults to the shortest option and can be changed', () async {
      expect(vm.stay, BookingViewModel.stayOptions.first);

      vm.setStay(const Duration(hours: 24));
      expect(vm.stay, const Duration(hours: 24));
    });

    test('purpose can be set, and reaches the booking', () async {
      await vm.openStation('ST-1');
      vm.selectCompartment(vm.availableCompartments.first);
      vm.setPurpose(ReservationPurpose.handover);

      await vm.submit('U1');

      expect(vm.confirmed?.purpose, ReservationPurpose.handover);
    });
  });

  group('submit', () {
    test('a successful booking is confirmed and locks the form', () async {
      await vm.openStation('ST-1');
      vm.selectCompartment(vm.availableCompartments.first);

      expect(await vm.submit('U1'), isTrue);

      expect(vm.isConfirmed, isTrue);
      expect(vm.confirmed?.state, ReservationState.confirmed);
      expect(vm.confirmed?.compartmentId, 'C1');
      expect(vm.canSubmit, isFalse, reason: 'no double booking from one form');
      expect(vm.hasError, isFalse);
    });

    test('the stay length decides the end time', () async {
      await vm.openStation('ST-1');
      vm.selectCompartment(vm.availableCompartments.first);
      vm.setStay(const Duration(hours: 24));

      await vm.submit('U1');

      final booking = vm.confirmed!;
      final held = booking.endTime.difference(booking.startTime);
      expect(held.inHours, closeTo(24, 1));
    });

    test('is submitting while the call is in flight', () async {
      final slow = InMemoryBookingRepository(
        lockers,
        delay: const Duration(milliseconds: 20),
      );
      final slowVm = BookingViewModel(slow, lockers);
      addTearDown(slowVm.dispose);

      await slowVm.openStation('ST-1');
      slowVm.selectCompartment(slowVm.availableCompartments.first);

      final future = slowVm.submit('U1');
      expect(slowVm.isSubmitting, isTrue);
      await future;
      expect(slowVm.isSubmitting, isFalse);
    });

    test('reset clears a confirmation so the screen can be reused', () async {
      await vm.openStation('ST-1');
      vm.selectCompartment(vm.availableCompartments.first);
      await vm.submit('U1');

      vm.reset();

      expect(vm.isConfirmed, isFalse);
      expect(vm.selected, isNull);
      expect(vm.hasError, isFalse);
    });
  });

  group('losing the race (E3 recovery)', () {
    Future<void> someoneElseTakes(String compartmentId) => bookings.book(
      userId: 'OTHER',
      stationId: 'ST-1',
      compartmentId: compartmentId,
      purpose: ReservationPurpose.parcel,
      end: DateTime.now().add(const Duration(hours: 2)),
    );

    test('a lost race offers the next free compartment', () async {
      await vm.openStation('ST-1');
      final chosen = vm.availableCompartments.first; // C1
      vm.selectCompartment(chosen);

      await someoneElseTakes('C1');

      expect(await vm.submit('U1'), isFalse);

      expect(vm.lostRace, isTrue);
      expect(vm.lostRaceAlternative, 'C2');
      expect(vm.error, contains('Someone just took'));
      expect(vm.isConfirmed, isFalse);
    });

    test('accepting the alternative books it in one step', () async {
      await vm.openStation('ST-1');
      vm.selectCompartment(vm.availableCompartments.first);
      await someoneElseTakes('C1');
      await vm.submit('U1');

      expect(await vm.acceptAlternative('U1'), isTrue);

      expect(vm.isConfirmed, isTrue);
      expect(vm.confirmed?.compartmentId, 'C2');
      expect(vm.lostRace, isFalse);
      expect(vm.hasError, isFalse);
    });

    test('if the alternative goes too, the user is told plainly', () async {
      await vm.openStation('ST-1');
      vm.selectCompartment(vm.availableCompartments.first);
      await someoneElseTakes('C1');
      await vm.submit('U1');
      expect(vm.lostRaceAlternative, 'C2');

      // The offered compartment is taken before the user accepts it.
      await someoneElseTakes('C2');

      expect(await vm.acceptAlternative('U1'), isFalse);
      expect(vm.error, contains('gone as well'));
      expect(vm.lostRace, isFalse);
      expect(vm.isConfirmed, isFalse);
    });

    test('no alternative is offered when the station is emptied', () async {
      await vm.openStation('ST-1');
      vm.selectCompartment(vm.availableCompartments.first);
      await someoneElseTakes('C1');
      await someoneElseTakes('C2');

      await vm.submit('U1');

      expect(vm.hasError, isTrue);
      expect(vm.lostRace, isFalse);
    });

    test('choosing another compartment clears the offer', () async {
      await vm.openStation('ST-1');
      vm.selectCompartment(vm.availableCompartments.first);
      await someoneElseTakes('C1');
      await vm.submit('U1');
      expect(vm.lostRace, isTrue);

      await vm.openStation('ST-1');
      vm.selectCompartment(vm.availableCompartments.first);

      expect(vm.lostRace, isFalse);
      expect(vm.hasError, isFalse);
    });

    test('acceptAlternative does nothing when there is no offer', () async {
      await vm.openStation('ST-1');
      expect(await vm.acceptAlternative('U1'), isFalse);
    });
  });

  group('refused windows', () {
    test('an over-long stay is reported, not silently clipped', () async {
      await vm.openStation('ST-1');
      vm.selectCompartment(vm.availableCompartments.first);
      vm.setStay(const Duration(hours: 100));

      expect(await vm.submit('U1'), isFalse);
      expect(vm.error, contains('72 hours'));
      expect(vm.isConfirmed, isFalse);
    });
  });
}
