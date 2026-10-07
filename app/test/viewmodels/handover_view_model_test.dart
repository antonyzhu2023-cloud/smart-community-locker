import 'package:flutter_test/flutter_test.dart';
import 'package:scls/models/compartment.dart';
import 'package:scls/models/locker_station.dart';
import 'package:scls/models/reservation.dart';
import 'package:scls/repositories/in_memory_access_backend.dart';
import 'package:scls/repositories/in_memory_auth_repository.dart';
import 'package:scls/repositories/in_memory_booking_repository.dart';
import 'package:scls/repositories/in_memory_locker_repository.dart';
import 'package:scls/viewmodels/handover_view_model.dart';

/// FR7, the feature Milestone 1 argued was the novel part of the system.
///
/// The rule being checked throughout is that the booking does not change
/// hands. The owner keeps it and keeps their own access. The neighbour gets
/// one token, good for one open, revocable until it is used.
void main() {
  late InMemoryLockerRepository lockers;
  late InMemoryBookingRepository bookings;
  late InMemoryAuthRepository auth;
  late InMemoryAccessBackend backend;
  late Reservation booking;
  late String ownerId;
  late String neighbourId;

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
          ],
        ),
      ],
    );
    bookings = InMemoryBookingRepository(lockers);
    auth = InMemoryAuthRepository();
    backend = InMemoryAccessBackend(lockers: lockers, bookings: bookings);

    final owner = await auth.register(
      email: 'owner@example.com',
      password: 'locker123',
      displayName: 'Ann Owner',
      membershipCode: 'WG-1041',
    );
    ownerId = owner.id;

    final neighbour = await auth.register(
      email: 'neighbour@example.com',
      password: 'locker123',
      displayName: 'Bob Neighbour',
      membershipCode: 'WG-1042',
    );
    neighbourId = neighbour.id;

    booking = await bookings.book(
      userId: ownerId,
      stationId: 'ST-1',
      compartmentId: 'C1',
      purpose: ReservationPurpose.handover,
      end: DateTime.now().add(const Duration(hours: 2)),
    );
  });

  tearDown(() async {
    await backend.dispose();
    auth.dispose();
  });

  HandoverViewModel build({Reservation? forBooking}) => HandoverViewModel(
    tokens: backend,
    auth: auth,
    reservation: forBooking ?? booking,
    ownerId: ownerId,
  );

  Future<HandoverViewModel> loaded() async {
    final vm = build();
    addTearDown(vm.dispose);
    await vm.load();
    return vm;
  }

  group('finding a neighbour', () {
    test('a verified resident is found by email', () async {
      final vm = await loaded();

      expect(await vm.findNeighbour('neighbour@example.com'), isTrue);
      expect(vm.found?.displayName, 'Bob Neighbour');
      expect(vm.hasError, isFalse);
    });

    test('the email is not case sensitive', () async {
      final vm = await loaded();
      expect(await vm.findNeighbour('  Neighbour@Example.COM '), isTrue);
    });

    test('an unknown address is refused', () async {
      final vm = await loaded();

      expect(await vm.findNeighbour('nobody@example.com'), isFalse);
      expect(vm.found, isNull);
      expect(vm.error, contains('No verified resident'));
    });

    test('an unverified account is reported the same as a missing one', () async {
      // Saying "that account exists but is not verified" would let anyone test
      // whether a given person lives in the building.
      await auth.register(
        email: 'visitor@example.com',
        password: 'locker123',
        displayName: 'No Code',
      );
      final vm = await loaded();

      expect(await vm.findNeighbour('visitor@example.com'), isFalse);
      expect(vm.error, contains('No verified resident'));
    });

    test('handing it to yourself is refused', () async {
      final vm = await loaded();

      expect(await vm.findNeighbour('owner@example.com'), isFalse);
      expect(vm.error, contains('your own account'));
    });

    test('an empty address is caught before the lookup', () async {
      final vm = await loaded();

      expect(await vm.findNeighbour('   '), isFalse);
      expect(vm.error, contains('email address'));
    });

    test('clearNeighbour drops the result', () async {
      final vm = await loaded();
      await vm.findNeighbour('neighbour@example.com');

      vm.clearNeighbour();

      expect(vm.found, isNull);
    });
  });

  group('handing over', () {
    test('needs a neighbour found first', () async {
      final vm = await loaded();

      expect(await vm.handOver(), isFalse);
      expect(vm.error, 'Find your neighbour first.');
    });

    test('issues one delegated token and says who has it', () async {
      final vm = await loaded();
      await vm.findNeighbour('neighbour@example.com');

      expect(await vm.handOver(), isTrue);

      expect(vm.liveHandovers, hasLength(1));
      expect(vm.liveHandovers.single.delegatedTo, neighbourId);
      expect(vm.notice, contains('Bob Neighbour'));
      expect(vm.hasError, isFalse);
    });

    test('the owner keeps their own access', () async {
      // The booking does not change hands. This is the whole design.
      final mine = await backend.issue(
        reservationId: booking.id,
        userId: ownerId,
      );
      final vm = await loaded();
      await vm.findNeighbour('neighbour@example.com');
      await vm.handOver();

      final outcome = await backend.present(
        stationId: 'ST-1',
        compartmentId: 'C1',
        payload: mine.signedPayload,
      );
      expect(outcome.accepted, isTrue);
    });

    test('the neighbour sees the booking they were given', () async {
      final vm = await loaded();
      await vm.findNeighbour('neighbour@example.com');
      await vm.handOver();

      // Without this the feature would only be a line of text on the giver's
      // screen and the neighbour could never open the locker.
      final theirs = await backend.delegationsTo(neighbourId);
      expect(theirs, hasLength(1));
      expect(theirs.single.reservationId, booking.id);

      final shared = await bookings.fetchBooking(theirs.single.reservationId);
      expect(shared?.compartmentId, 'C1');
    });

    test('the neighbour can open the locker once', () async {
      final vm = await loaded();
      await vm.findNeighbour('neighbour@example.com');
      await vm.handOver();
      final theirs = (await backend.delegationsTo(neighbourId)).single;

      expect(
        (await backend.present(
          stationId: 'ST-1',
          compartmentId: 'C1',
          payload: theirs.signedPayload,
        )).accepted,
        isTrue,
      );
      expect(
        (await backend.present(
          stationId: 'ST-1',
          compartmentId: 'C1',
          payload: theirs.signedPayload,
        )).accepted,
        isFalse,
      );
    });

    test('a used hand-over no longer shows as live', () async {
      final vm = await loaded();
      await vm.findNeighbour('neighbour@example.com');
      await vm.handOver();
      final theirs = (await backend.delegationsTo(neighbourId)).single;

      await backend.present(
        stationId: 'ST-1',
        compartmentId: 'C1',
        payload: theirs.signedPayload,
      );
      await vm.load();

      expect(vm.hasLiveHandover, isFalse);
      expect(await backend.delegationsTo(neighbourId), isEmpty);
    });

    test('a finished booking cannot be given away', () async {
      await bookings.cancel(booking.id);
      final cancelled = (await bookings.fetchBooking(booking.id))!;
      final vm = build(forBooking: cancelled);
      addTearDown(vm.dispose);
      await vm.load();

      expect(vm.canHandOver, isFalse);

      await vm.findNeighbour('neighbour@example.com');
      expect(await vm.handOver(), isFalse);
      expect(vm.error, contains('no longer active'));
    });

    test('two neighbours can each be given one', () async {
      await auth.register(
        email: 'third@example.com',
        password: 'locker123',
        displayName: 'Cal Third',
        membershipCode: 'SH-0207',
      );
      final vm = await loaded();

      await vm.findNeighbour('neighbour@example.com');
      await vm.handOver();
      await vm.findNeighbour('third@example.com');
      await vm.handOver();

      expect(vm.liveHandovers, hasLength(2));
    });
  });

  group('taking it back', () {
    test('a revoked hand-over no longer opens the locker', () async {
      final vm = await loaded();
      await vm.findNeighbour('neighbour@example.com');
      await vm.handOver();
      final theirs = (await backend.delegationsTo(neighbourId)).single;

      expect(await vm.takeBack(theirs.id), isTrue);

      final outcome = await backend.present(
        stationId: 'ST-1',
        compartmentId: 'C1',
        payload: theirs.signedPayload,
      );
      expect(outcome.accepted, isFalse);
    });

    test('it disappears from both lists', () async {
      final vm = await loaded();
      await vm.findNeighbour('neighbour@example.com');
      await vm.handOver();
      final theirs = (await backend.delegationsTo(neighbourId)).single;

      await vm.takeBack(theirs.id);

      expect(vm.hasLiveHandover, isFalse);
      expect(await backend.delegationsTo(neighbourId), isEmpty);
    });

    test('taking back one leaves the other alone', () async {
      await auth.register(
        email: 'third@example.com',
        password: 'locker123',
        displayName: 'Cal Third',
        membershipCode: 'SH-0207',
      );
      final vm = await loaded();
      await vm.findNeighbour('neighbour@example.com');
      await vm.handOver();
      await vm.findNeighbour('third@example.com');
      await vm.handOver();

      await vm.takeBack(vm.liveHandovers.first.id);

      expect(vm.liveHandovers, hasLength(1));
    });

    test('taking back twice reports a message rather than throwing', () async {
      final vm = await loaded();
      await vm.findNeighbour('neighbour@example.com');
      await vm.handOver();
      final id = vm.liveHandovers.single.id;

      await vm.takeBack(id);

      expect(await vm.takeBack(id), isFalse);
      expect(vm.error, isNotNull);
    });

    test('a hand-over that has been used cannot be taken back', () async {
      // FR7 says revocable before use. After use there is nothing to revoke,
      // and pretending otherwise would tell the owner their locker is safe
      // when it has already been opened.
      final vm = await loaded();
      await vm.findNeighbour('neighbour@example.com');
      await vm.handOver();
      final theirs = (await backend.delegationsTo(neighbourId)).single;
      await backend.present(
        stationId: 'ST-1',
        compartmentId: 'C1',
        payload: theirs.signedPayload,
      );

      expect(await vm.takeBack(theirs.id), isFalse);
      // The message has to say it was used. Saying "already withdrawn" would
      // leave the owner thinking the locker was never opened.
      expect(vm.error, contains('already been used'));
    });
  });

  group('messages', () {
    test('a notice and an error are separate pieces of state', () async {
      final vm = await loaded();
      await vm.findNeighbour('neighbour@example.com');
      await vm.handOver();
      expect(vm.notice, isNotNull);
      expect(vm.hasError, isFalse);

      await vm.findNeighbour('nobody@example.com');
      expect(vm.hasError, isTrue);
      expect(vm.notice, isNull);
    });

    test('clearMessages removes both and notifies once', () async {
      final vm = await loaded();
      await vm.findNeighbour('nobody@example.com');

      var notifications = 0;
      vm.addListener(() => notifications++);
      vm.clearMessages();

      expect(vm.hasError, isFalse);
      expect(notifications, 1);
    });

    test('clearMessages is a no-op when there is nothing to clear', () async {
      final vm = await loaded();

      var notifications = 0;
      vm.addListener(() => notifications++);
      vm.clearMessages();

      expect(notifications, 0);
    });
  });
}
