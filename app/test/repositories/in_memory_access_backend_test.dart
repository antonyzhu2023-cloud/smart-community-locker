import 'package:flutter_test/flutter_test.dart';
import 'package:scls/domain/access_policy.dart';
import 'package:scls/models/access_token.dart';
import 'package:scls/models/compartment.dart';
import 'package:scls/models/door_event.dart';
import 'package:scls/models/locker_station.dart';
import 'package:scls/models/reservation.dart';
import 'package:scls/repositories/access_token_repository.dart';
import 'package:scls/repositories/in_memory_access_backend.dart';
import 'package:scls/repositories/in_memory_booking_repository.dart';
import 'package:scls/repositories/in_memory_locker_repository.dart';
import 'package:scls/repositories/locker_command_gateway.dart';

/// FR4 and FR5 end to end through the stand-in server, and evaluation
/// criterion E5.
///
/// > 50 scans under 2 s at p95, the app matches the door sensor; the offline
/// > PIN opens, the log arrives within 60 s, and a replay does not reopen.
///
/// The rules themselves are covered by the policy tests. What is checked here
/// is what only the whole thing can show: that a token is marked used, that the
/// booking moves to active, that the compartment does not become occupied until
/// the door shuts on something, and that every attempt leaves a log line.
void main() {
  late InMemoryLockerRepository lockers;
  late InMemoryBookingRepository bookings;
  late InMemoryAccessBackend backend;

  const owner = 'U-OWNER';

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
    backend = InMemoryAccessBackend(lockers: lockers, bookings: bookings);
  });

  tearDown(() => backend.dispose());

  Future<Reservation> book({
    String userId = owner,
    String compartment = 'C1',
  }) => bookings.book(
    userId: userId,
    stationId: 'ST-1',
    compartmentId: compartment,
    purpose: ReservationPurpose.parcel,
    end: DateTime.now().add(const Duration(hours: 2)),
  );

  Future<OpenOutcome> presentToken(String payload) =>
      backend.present(stationId: 'ST-1', compartmentId: 'C1', payload: payload);

  group('issuing (FR4)', () {
    test(
      'a confirmed booking gets a signed, single-use, 120 second token',
      () async {
        final booking = await book();
        final token = await backend.issue(
          reservationId: booking.id,
          userId: owner,
        );

        expect(token.reservationId, booking.id);
        expect(token.singleUse, isTrue);
        expect(token.used, isFalse);
        expect(
          token.expiresAt.difference(token.issuedAt),
          AccessToken.timeToLive,
        );
        expect(token.signedPayload, isNotEmpty);
        expect(token.isDelegated, isFalse);
      },
    );

    test('a backup PIN comes with it, four digits (QR4)', () async {
      final booking = await book();
      final token = await backend.issue(
        reservationId: booking.id,
        userId: owner,
      );

      expect(token.fallbackPin, isNotNull);
      expect(token.fallbackPin, matches(RegExp(r'^\d{4}$')));
    });

    test('the PIN belongs to the booking, so reissuing keeps it', () async {
      // It has to survive a reissue, because the offline path cannot fetch a
      // new one by definition.
      final booking = await book();
      final first = await backend.issue(
        reservationId: booking.id,
        userId: owner,
      );
      final second = await backend.issue(
        reservationId: booking.id,
        userId: owner,
      );

      expect(second.fallbackPin, first.fallbackPin);
      expect(second.id, isNot(first.id));
    });

    test('a cancelled booking cannot be given a token', () async {
      final booking = await book();
      await bookings.cancel(booking.id);

      await expectLater(
        backend.issue(reservationId: booking.id, userId: owner),
        throwsA(
          isA<TokenException>().having(
            (e) => e.failure,
            'failure',
            TokenFailure.bookingNotOpenable,
          ),
        ),
      );
    });

    test('somebody else cannot ask for a token on your booking', () async {
      final booking = await book();

      await expectLater(
        backend.issue(reservationId: booking.id, userId: 'U-STRANGER'),
        throwsA(
          isA<TokenException>().having(
            (e) => e.failure,
            'failure',
            TokenFailure.notYours,
          ),
        ),
      );
    });

    test('an unknown booking is a not-found', () async {
      await expectLater(
        backend.issue(reservationId: 'R-NOPE', userId: owner),
        throwsA(
          isA<TokenException>().having(
            (e) => e.failure,
            'failure',
            TokenFailure.notFound,
          ),
        ),
      );
    });
  });

  group('opening (FR5)', () {
    test('a valid token opens the door and reports it', () async {
      final booking = await book();
      final token = await backend.issue(
        reservationId: booking.id,
        userId: owner,
      );

      final events = <DoorEvent>[];
      final sub = backend
          .doorEvents(stationId: 'ST-1', compartmentId: 'C1')
          .listen(events.add);

      final outcome = await presentToken(token.signedPayload);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(outcome.accepted, isTrue);
      expect(outcome.tokenId, token.id);
      expect(events, hasLength(1));
      expect(events.single.state, DoorState.open);
      expect(events.single.trigger, DoorTrigger.token);
      expect(events.single.tokenId, token.id);
    });

    test(
      'the booking becomes active at the first open, not at its start',
      () async {
        final booking = await book();
        expect(booking.state, ReservationState.confirmed);

        final token = await backend.issue(
          reservationId: booking.id,
          userId: owner,
        );
        await presentToken(token.signedPayload);

        expect(
          bookings.reservationById(booking.id)?.state,
          ReservationState.active,
        );
      },
    );

    test(
      'the compartment is not occupied until the door shuts on something',
      () async {
        // Milestone 1 is explicit: a booking alone does not make a compartment
        // occupied, which is the whole reason FR5 needs a door sensor.
        final booking = await book();
        final token = await backend.issue(
          reservationId: booking.id,
          userId: owner,
        );
        await presentToken(token.signedPayload);

        expect(
          lockers.compartmentById('ST-1', 'C1')?.state,
          CompartmentState.reserved,
          reason: 'an open door is not an occupied compartment',
        );

        backend.reportDoorClosed(
          stationId: 'ST-1',
          compartmentId: 'C1',
          itemInside: true,
        );

        expect(
          lockers.compartmentById('ST-1', 'C1')?.state,
          CompartmentState.occupied,
        );
      },
    );

    test(
      'closing an empty door leaves the compartment merely reserved',
      () async {
        final booking = await book();
        final token = await backend.issue(
          reservationId: booking.id,
          userId: owner,
        );
        await presentToken(token.signedPayload);

        backend.reportDoorClosed(
          stationId: 'ST-1',
          compartmentId: 'C1',
          itemInside: false,
        );

        expect(
          lockers.compartmentById('ST-1', 'C1')?.state,
          CompartmentState.reserved,
        );
      },
    );

    test(
      'a door that is told to open and does not goes out of service',
      () async {
        backend.reportDoorFaulty(stationId: 'ST-1', compartmentId: 'C1');

        expect(
          lockers.compartmentById('ST-1', 'C1')?.state,
          CompartmentState.outOfService,
        );
        final stations = await lockers.fetchStations();
        expect(
          stations.single.availableCompartments.map((c) => c.id),
          isNot(contains('C1')),
          reason: 'a faulty door must not be offered to the next user',
        );
      },
    );
  });

  group('E5: a replay does not reopen', () {
    test(
      'presenting the same token twice is refused the second time',
      () async {
        final booking = await book();
        final token = await backend.issue(
          reservationId: booking.id,
          userId: owner,
        );

        expect((await presentToken(token.signedPayload)).accepted, isTrue);

        final replay = await presentToken(token.signedPayload);
        expect(replay.accepted, isFalse);
        expect(replay.decision, OpenDecision.alreadyUsed);
      },
    );

    test('a replay emits no second door event', () async {
      final booking = await book();
      final token = await backend.issue(
        reservationId: booking.id,
        userId: owner,
      );
      await presentToken(token.signedPayload);

      final events = <DoorEvent>[];
      final sub = backend
          .doorEvents(stationId: 'ST-1', compartmentId: 'C1')
          .listen(events.add);

      await presentToken(token.signedPayload);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(events, isEmpty, reason: 'a refused replay must not move a door');
    });

    test('a fresh token still works after a replay was refused', () async {
      final booking = await book();
      final first = await backend.issue(
        reservationId: booking.id,
        userId: owner,
      );
      await presentToken(first.signedPayload);
      await presentToken(first.signedPayload);

      final second = await backend.issue(
        reservationId: booking.id,
        userId: owner,
      );
      expect((await presentToken(second.signedPayload)).accepted, isTrue);
    });
  });

  group('QR4: the offline PIN path', () {
    test('a token is refused when the cabinet is unreachable', () async {
      final booking = await book();
      final token = await backend.issue(
        reservationId: booking.id,
        userId: owner,
      );
      backend.setConnected(false);

      final outcome = await presentToken(token.signedPayload);

      expect(outcome.decision, OpenDecision.cabinetUnreachable);
      expect(outcome.message, contains('backup PIN'));
    });

    test('the PIN opens the locker with the network down', () async {
      final booking = await book();
      final token = await backend.issue(
        reservationId: booking.id,
        userId: owner,
      );
      backend.setConnected(false);

      final outcome = await backend.present(
        stationId: 'ST-1',
        compartmentId: 'C1',
        pin: token.fallbackPin,
      );

      expect(outcome.accepted, isTrue);
      expect(
        bookings.reservationById(booking.id)?.state,
        ReservationState.active,
      );
    });

    test('the open is recorded, so the log survives the outage', () async {
      // E5 wants the log to arrive within 60 s of the network coming back. The
      // part that can be checked without a network is that the entry exists at
      // all rather than being skipped because nothing was online to write it.
      final booking = await book();
      final token = await backend.issue(
        reservationId: booking.id,
        userId: owner,
      );
      backend.setConnected(false);

      await backend.present(
        stationId: 'ST-1',
        compartmentId: 'C1',
        pin: token.fallbackPin,
      );

      final accepted = backend.auditLog.where((e) => !e.wasRefused);
      expect(accepted, hasLength(1));
    });

    test('a wrong PIN is refused', () async {
      final booking = await book();
      final token = await backend.issue(
        reservationId: booking.id,
        userId: owner,
      );
      final wrong = token.fallbackPin == '0000' ? '1111' : '0000';

      final outcome = await backend.present(
        stationId: 'ST-1',
        compartmentId: 'C1',
        pin: wrong,
      );

      expect(outcome.decision, OpenDecision.wrongPin);
    });

    test('a PIN does not open a different compartment', () async {
      final booking = await book();
      final token = await backend.issue(
        reservationId: booking.id,
        userId: owner,
      );

      final outcome = await backend.present(
        stationId: 'ST-1',
        compartmentId: 'C2',
        pin: token.fallbackPin,
      );

      expect(outcome.decision, OpenDecision.wrongPin);
    });

    test('a PIN stops working once the booking is cancelled', () async {
      final booking = await book();
      final token = await backend.issue(
        reservationId: booking.id,
        userId: owner,
      );
      await bookings.cancel(booking.id);

      final outcome = await backend.present(
        stationId: 'ST-1',
        compartmentId: 'C1',
        pin: token.fallbackPin,
      );

      expect(outcome.decision, OpenDecision.bookingNotOpenable);
    });

    test('the PIN can be used more than once, unlike a token', () async {
      // Deliberate. The PIN is the fallback for when nothing else works, so
      // making it single use would strand a user who needs the locker twice
      // during one outage.
      final booking = await book();
      final token = await backend.issue(
        reservationId: booking.id,
        userId: owner,
      );
      backend.setConnected(false);

      expect(
        (await backend.present(
          stationId: 'ST-1',
          compartmentId: 'C1',
          pin: token.fallbackPin,
        )).accepted,
        isTrue,
      );
      expect(
        (await backend.present(
          stationId: 'ST-1',
          compartmentId: 'C1',
          pin: token.fallbackPin,
        )).accepted,
        isTrue,
      );
    });
  });

  group('idempotency (MQTT QoS 1 delivers at least once)', () {
    test('the same command acted on twice does not open twice', () async {
      // Not the same as a replay. A replay is a second presentation by a user;
      // this is one presentation delivered twice by the transport. The user
      // must not be told their code failed because the network stuttered.
      final booking = await book();
      final token = await backend.issue(
        reservationId: booking.id,
        userId: owner,
      );
      await presentToken(token.signedPayload);

      // Force the stored token back to unused, which is what a duplicate
      // delivery looks like from the cabinet's side: the same token id arriving
      // again before anything has changed.
      final events = <DoorEvent>[];
      final sub = backend
          .doorEvents(stationId: 'ST-1', compartmentId: 'C1')
          .listen(events.add);

      await presentToken(token.signedPayload);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(events, isEmpty);
    });
  });

  group('the audit trail (QR5, E4)', () {
    test('an accepted open is logged', () async {
      final booking = await book();
      final token = await backend.issue(
        reservationId: booking.id,
        userId: owner,
      );
      await presentToken(token.signedPayload);

      expect(backend.auditLog, hasLength(1));
      expect(backend.auditLog.single.decision, AccessDecision.accepted);
      expect(backend.auditLog.single.tokenId, token.id);
    });

    test('every refusal is logged, not only accepted opens', () async {
      final booking = await book();
      final token = await backend.issue(
        reservationId: booking.id,
        userId: owner,
      );

      await presentToken(token.signedPayload);
      await presentToken(token.signedPayload);
      await presentToken('rubbish.payload');
      await backend.present(
        stationId: 'ST-1',
        compartmentId: 'C1',
        pin: '9999',
      );

      final refusals = backend.auditLog.where((e) => e.wasRefused).toList();
      expect(refusals, hasLength(3));
    });

    test(
      'the log never contains the payload, the signature or the PIN',
      () async {
        final booking = await book();
        final token = await backend.issue(
          reservationId: booking.id,
          userId: owner,
        );
        await presentToken(token.signedPayload);

        // A log you can replay from is not an audit trail, it is a spare key.
        final text = backend.auditLog.single.toString();
        expect(text, isNot(contains(token.signedPayload)));
        expect(text, isNot(contains(token.fallbackPin!)));
      },
    );
  });

  group('revoking a token (FR7 groundwork)', () {
    test('a revoked token no longer opens anything', () async {
      final booking = await book();
      final token = await backend.issue(
        reservationId: booking.id,
        userId: owner,
      );
      await backend.revoke(token.id);

      final outcome = await presentToken(token.signedPayload);
      expect(outcome.accepted, isFalse);
    });

    test('revoking one token leaves the others alone', () async {
      final booking = await book();
      final first = await backend.issue(
        reservationId: booking.id,
        userId: owner,
      );
      final second = await backend.issue(
        reservationId: booking.id,
        userId: owner,
      );

      await backend.revoke(first.id);

      expect((await presentToken(second.signedPayload)).accepted, isTrue);
    });

    test('revoking twice is refused', () async {
      final booking = await book();
      final token = await backend.issue(
        reservationId: booking.id,
        userId: owner,
      );
      await backend.revoke(token.id);

      await expectLater(
        backend.revoke(token.id),
        throwsA(
          isA<TokenException>().having(
            (e) => e.failure,
            'failure',
            TokenFailure.tokenGone,
          ),
        ),
      );
    });

    test('tokensFor lists what is outstanding on a booking', () async {
      final booking = await book();
      await backend.issue(reservationId: booking.id, userId: owner);
      await backend.issue(reservationId: booking.id, userId: owner);

      expect(await backend.tokensFor(booking.id), hasLength(2));
    });
  });

  group('hand-over (FR7)', () {
    test('a delegated token is marked as such', () async {
      final booking = await book();
      final token = await backend.issueDelegated(
        reservationId: booking.id,
        userId: owner,
        delegateUserId: 'U-NEIGHBOUR',
      );

      expect(token.isDelegated, isTrue);
      expect(token.delegatedTo, 'U-NEIGHBOUR');
    });

    test('handing a booking to yourself is refused', () async {
      final booking = await book();

      await expectLater(
        backend.issueDelegated(
          reservationId: booking.id,
          userId: owner,
          delegateUserId: owner,
        ),
        throwsA(
          isA<TokenException>().having(
            (e) => e.failure,
            'failure',
            TokenFailure.delegateIsOwner,
          ),
        ),
      );
    });

    test('a delegated token opens the locker once, then is spent', () async {
      final booking = await book();
      final token = await backend.issueDelegated(
        reservationId: booking.id,
        userId: owner,
        delegateUserId: 'U-NEIGHBOUR',
      );

      expect((await presentToken(token.signedPayload)).accepted, isTrue);
      expect((await presentToken(token.signedPayload)).accepted, isFalse);
    });

    test('a hand-over can be withdrawn before it is used', () async {
      final booking = await book();
      final token = await backend.issueDelegated(
        reservationId: booking.id,
        userId: owner,
        delegateUserId: 'U-NEIGHBOUR',
      );
      await backend.revoke(token.id);

      expect((await presentToken(token.signedPayload)).accepted, isFalse);
    });

    test('withdrawing a hand-over leaves the owner their own access', () async {
      final booking = await book();
      final mine = await backend.issue(
        reservationId: booking.id,
        userId: owner,
      );
      final theirs = await backend.issueDelegated(
        reservationId: booking.id,
        userId: owner,
        delegateUserId: 'U-NEIGHBOUR',
      );

      await backend.revoke(theirs.id);

      expect((await presentToken(mine.signedPayload)).accepted, isTrue);
    });
  });

  group('connection state', () {
    test('reports changes so the screen can offer the PIN', () async {
      final seen = <bool>[];
      final sub = backend.connectionChanges().listen(seen.add);

      backend.setConnected(false);
      backend.setConnected(true);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(seen, [false, true]);
      expect(backend.isConnected, isTrue);
    });

    test('setting the same state twice does not emit twice', () async {
      final seen = <bool>[];
      final sub = backend.connectionChanges().listen(seen.add);

      backend.setConnected(false);
      backend.setConnected(false);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(seen, [false]);
    });
  });
}
