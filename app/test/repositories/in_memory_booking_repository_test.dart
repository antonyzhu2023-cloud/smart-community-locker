import 'package:flutter_test/flutter_test.dart';
import 'package:scls/models/compartment.dart';
import 'package:scls/models/locker_station.dart';
import 'package:scls/models/reservation.dart';
import 'package:scls/repositories/booking_repository.dart';
import 'package:scls/repositories/in_memory_booking_repository.dart';
import 'package:scls/repositories/in_memory_locker_repository.dart';

void main() {
  late InMemoryLockerRepository lockers;
  late InMemoryBookingRepository bookings;

  LockerStation testStation({
    StationStatus status = StationStatus.online,
    List<Compartment>? compartments,
  }) {
    return LockerStation(
      id: 'ST-1',
      name: 'Test Station',
      latitude: -36.85,
      longitude: 174.76,
      status: status,
      compartments:
          compartments ??
          [
            const Compartment(
              id: 'C1',
              size: SizeClass.small,
              state: CompartmentState.free,
            ),
            const Compartment(
              id: 'C2',
              size: SizeClass.small,
              state: CompartmentState.free,
            ),
            const Compartment(
              id: 'C3',
              size: SizeClass.medium,
              state: CompartmentState.free,
            ),
            const Compartment(
              id: 'C4',
              size: SizeClass.large,
              state: CompartmentState.outOfService,
            ),
          ],
    );
  }

  setUp(() {
    lockers = InMemoryLockerRepository(stations: [testStation()]);
    bookings = InMemoryBookingRepository(lockers);
  });

  DateTime inHours(int h) => DateTime.now().add(Duration(hours: h));

  Future<Reservation> bookC1({String userId = 'U1'}) => bookings.book(
    userId: userId,
    stationId: 'ST-1',
    compartmentId: 'C1',
    purpose: ReservationPurpose.parcel,
    end: inHours(2),
  );

  group('book', () {
    test('a free compartment is confirmed and held', () async {
      final booking = await bookC1();

      expect(booking.state, ReservationState.confirmed);
      expect(booking.compartmentId, 'C1');
      expect(booking.canIssueToken, isTrue);

      // The hold is visible to the station list straight away.
      expect(
        lockers.compartmentById('ST-1', 'C1')?.state,
        CompartmentState.reserved,
      );
      final stations = await lockers.fetchStations();
      expect(stations.single.freeCount, 2);
    });

    test('a second booking of the same compartment is refused', () async {
      await bookC1();

      await expectLater(
        bookC1(userId: 'U2'),
        throwsA(
          isA<BookingException>().having(
            (e) => e.failure,
            'failure',
            BookingFailure.compartmentTaken,
          ),
        ),
      );
    });

    test('the loser is offered the next free compartment of that size', () async {
      await bookC1();

      try {
        await bookC1(userId: 'U2');
        fail('the second booking should have been refused');
      } on BookingException catch (e) {
        // Milestone 1: on a lost race the app offers an alternative rather than
        // showing an error and sending the user back to the list.
        expect(e.hasAlternative, isTrue);
        expect(e.alternative, 'C2');
      }
    });

    test(
      'no alternative is offered when nothing of that size is left',
      () async {
        await bookC1();
        await bookings.book(
          userId: 'U2',
          stationId: 'ST-1',
          compartmentId: 'C2',
          purpose: ReservationPurpose.parcel,
          end: inHours(2),
        );

        try {
          await bookC1(userId: 'U3');
          fail('the third booking should have been refused');
        } on BookingException catch (e) {
          expect(e.failure, BookingFailure.compartmentTaken);
          expect(e.hasAlternative, isFalse);
        }
      },
    );

    test('an out of service compartment cannot be booked', () async {
      await expectLater(
        bookings.book(
          userId: 'U1',
          stationId: 'ST-1',
          compartmentId: 'C4',
          purpose: ReservationPurpose.storage,
          end: inHours(2),
        ),
        throwsA(
          isA<BookingException>().having(
            (e) => e.failure,
            'failure',
            BookingFailure.compartmentUnusable,
          ),
        ),
      );
    });

    test('an offline station cannot be booked', () async {
      final offline = InMemoryLockerRepository(
        stations: [testStation(status: StationStatus.offline)],
      );
      final repo = InMemoryBookingRepository(offline);

      await expectLater(
        repo.book(
          userId: 'U1',
          stationId: 'ST-1',
          compartmentId: 'C1',
          purpose: ReservationPurpose.parcel,
          end: inHours(2),
        ),
        throwsA(
          isA<BookingException>().having(
            (e) => e.failure,
            'failure',
            BookingFailure.compartmentUnusable,
          ),
        ),
      );
    });

    test(
      'an unknown station or compartment is a not-found, not a crash',
      () async {
        await expectLater(
          bookings.book(
            userId: 'U1',
            stationId: 'NOPE',
            compartmentId: 'C1',
            purpose: ReservationPurpose.parcel,
            end: inHours(2),
          ),
          throwsA(
            isA<BookingException>().having(
              (e) => e.failure,
              'failure',
              BookingFailure.notFound,
            ),
          ),
        );

        await expectLater(
          bookings.book(
            userId: 'U1',
            stationId: 'ST-1',
            compartmentId: 'NOPE',
            purpose: ReservationPurpose.parcel,
            end: inHours(2),
          ),
          throwsA(
            isA<BookingException>().having(
              (e) => e.failure,
              'failure',
              BookingFailure.notFound,
            ),
          ),
        );
      },
    );

    group('time window', () {
      test('an end time in the past is refused', () async {
        await expectLater(
          bookings.book(
            userId: 'U1',
            stationId: 'ST-1',
            compartmentId: 'C1',
            purpose: ReservationPurpose.parcel,
            end: DateTime.now().subtract(const Duration(minutes: 1)),
          ),
          throwsA(
            isA<BookingException>().having(
              (e) => e.failure,
              'failure',
              BookingFailure.invalidWindow,
            ),
          ),
        );
      });

      test('beyond the 72 hour maximum stay is refused', () async {
        await expectLater(
          bookings.book(
            userId: 'U1',
            stationId: 'ST-1',
            compartmentId: 'C1',
            purpose: ReservationPurpose.storage,
            end: inHours(73),
          ),
          throwsA(
            isA<BookingException>().having(
              (e) => e.failure,
              'failure',
              BookingFailure.invalidWindow,
            ),
          ),
        );
      });

      test('a refused window leaves the compartment free', () async {
        await expectLater(
          bookings.book(
            userId: 'U1',
            stationId: 'ST-1',
            compartmentId: 'C1',
            purpose: ReservationPurpose.storage,
            end: inHours(73),
          ),
          throwsA(isA<BookingException>()),
        );
        expect(
          lockers.compartmentById('ST-1', 'C1')?.state,
          CompartmentState.free,
        );
      });
    });

    group('eligibility (E1)', () {
      test('an ineligible account is refused below the UI', () async {
        final guarded = InMemoryBookingRepository(
          lockers,
          isEligible: (userId) => userId == 'VERIFIED',
        );

        await expectLater(
          guarded.book(
            userId: 'UNVERIFIED',
            stationId: 'ST-1',
            compartmentId: 'C1',
            purpose: ReservationPurpose.parcel,
            end: inHours(2),
          ),
          throwsA(
            isA<BookingException>().having(
              (e) => e.failure,
              'failure',
              BookingFailure.notEligible,
            ),
          ),
        );

        // The screen the user can reach already stops this. Checking it here as
        // well means the rule does not depend on the UI being correct, which is
        // the same reason it is repeated in the Firestore security rules.
        expect(
          lockers.compartmentById('ST-1', 'C1')?.state,
          CompartmentState.free,
        );
      });

      test('a verified account goes through', () async {
        final guarded = InMemoryBookingRepository(
          lockers,
          isEligible: (userId) => userId == 'VERIFIED',
        );

        final booking = await guarded.book(
          userId: 'VERIFIED',
          stationId: 'ST-1',
          compartmentId: 'C1',
          purpose: ReservationPurpose.parcel,
          end: inHours(2),
        );
        expect(booking.state, ReservationState.confirmed);
      });
    });
  });

  group('E3: concurrent bookings', () {
    test('ten simultaneous requests produce exactly one confirmation', () async {
      // Evaluation criterion E3. Every request is launched before any of them
      // is awaited, so they interleave at the repository rather than running
      // one after another. With a slow backend this is the realistic case: ten
      // residents tapping the same locker in the same second.
      final slow = InMemoryBookingRepository(
        lockers,
        delay: const Duration(milliseconds: 5),
      );

      final attempts = [
        for (var i = 0; i < 10; i++)
          slow
              .book(
                userId: 'U$i',
                stationId: 'ST-1',
                compartmentId: 'C1',
                purpose: ReservationPurpose.parcel,
                end: inHours(2),
              )
              .then<Object?>((r) => r)
              .catchError((Object e) => e),
      ];

      final results = await Future.wait(attempts);

      final confirmed = results.whereType<Reservation>().toList();
      final refused = results.whereType<BookingException>().toList();

      expect(confirmed, hasLength(1), reason: 'exactly one booking may win');
      expect(refused, hasLength(9));
      expect(
        refused.every((e) => e.failure == BookingFailure.compartmentTaken),
        isTrue,
      );

      // And the nine losers were all offered somewhere else to go.
      expect(refused.every((e) => e.hasAlternative), isTrue);

      // The cabinet is left consistent: one door held, not ten.
      final stations = await lockers.fetchStations();
      expect(stations.single.freeCount, 2);
    });

    test(
      'ten requests across two compartments fill both exactly once',
      () async {
        final slow = InMemoryBookingRepository(
          lockers,
          delay: const Duration(milliseconds: 5),
        );

        final attempts = [
          for (var i = 0; i < 10; i++)
            slow
                .book(
                  userId: 'U$i',
                  stationId: 'ST-1',
                  compartmentId: i.isEven ? 'C1' : 'C2',
                  purpose: ReservationPurpose.parcel,
                  end: inHours(2),
                )
                .then<Object?>((r) => r)
                .catchError((Object e) => e),
        ];

        final results = await Future.wait(attempts);
        final confirmed = results.whereType<Reservation>().toList();

        expect(confirmed, hasLength(2));
        expect(confirmed.map((r) => r.compartmentId).toSet(), {
          'C1',
          'C2',
        }, reason: 'one winner per compartment, not two for one door');
      },
    );
  });

  group('fetchBookings', () {
    test('returns one user only, newest first', () async {
      final first = await bookC1();
      final second = await bookings.book(
        userId: 'U1',
        stationId: 'ST-1',
        compartmentId: 'C2',
        purpose: ReservationPurpose.handover,
        end: inHours(3),
      );
      await bookings.book(
        userId: 'U2',
        stationId: 'ST-1',
        compartmentId: 'C3',
        purpose: ReservationPurpose.parcel,
        end: inHours(1),
      );

      final mine = await bookings.fetchBookings('U1');

      expect(mine, hasLength(2));
      expect(mine.map((r) => r.id), containsAll([first.id, second.id]));
      expect(
        mine.first.startTime.isBefore(mine.last.startTime),
        isFalse,
        reason: 'newest first',
      );
    });

    test('a user with no bookings gets an empty list, not an error', () async {
      expect(await bookings.fetchBookings('NOBODY'), isEmpty);
    });
  });

  group('cancel', () {
    test('releases the compartment', () async {
      final booking = await bookC1();
      final cancelled = await bookings.cancel(booking.id);

      expect(cancelled.state, ReservationState.cancelled);
      expect(cancelled.canIssueToken, isFalse);
      expect(
        lockers.compartmentById('ST-1', 'C1')?.state,
        CompartmentState.free,
      );
    });

    test('the released compartment can be booked by someone else', () async {
      final booking = await bookC1();
      await bookings.cancel(booking.id);

      final second = await bookC1(userId: 'U2');
      expect(second.state, ReservationState.confirmed);
    });

    test('cancelling twice is refused', () async {
      final booking = await bookC1();
      await bookings.cancel(booking.id);

      await expectLater(
        bookings.cancel(booking.id),
        throwsA(
          isA<BookingException>().having(
            (e) => e.failure,
            'failure',
            BookingFailure.bookingFinished,
          ),
        ),
      );
    });

    test('an unknown booking is a not-found', () async {
      await expectLater(
        bookings.cancel('R999'),
        throwsA(
          isA<BookingException>().having(
            (e) => e.failure,
            'failure',
            BookingFailure.notFound,
          ),
        ),
      );
    });
  });

  group('extend', () {
    test('pushes the end time out', () async {
      final booking = await bookC1();
      final newEnd = booking.endTime.add(const Duration(hours: 2));

      final extended = await bookings.extend(booking.id, newEnd);

      expect(extended.endTime, newEnd);
      expect(extended.state, booking.state);
      expect(extended.id, booking.id);
    });

    test('an earlier end time is refused', () async {
      final booking = await bookC1();

      await expectLater(
        bookings.extend(
          booking.id,
          booking.endTime.subtract(const Duration(minutes: 30)),
        ),
        throwsA(
          isA<BookingException>().having(
            (e) => e.failure,
            'failure',
            BookingFailure.invalidWindow,
          ),
        ),
      );
    });

    test('cannot extend past the 72 hour total', () async {
      final booking = await bookC1();

      await expectLater(
        bookings.extend(
          booking.id,
          booking.startTime.add(const Duration(hours: 73)),
        ),
        throwsA(
          isA<BookingException>().having(
            (e) => e.failure,
            'failure',
            BookingFailure.invalidWindow,
          ),
        ),
      );
    });

    test('a cancelled booking cannot be extended', () async {
      final booking = await bookC1();
      await bookings.cancel(booking.id);

      await expectLater(
        bookings.extend(
          booking.id,
          booking.endTime.add(const Duration(hours: 1)),
        ),
        throwsA(
          isA<BookingException>().having(
            (e) => e.failure,
            'failure',
            BookingFailure.bookingFinished,
          ),
        ),
      );
    });
  });
}
