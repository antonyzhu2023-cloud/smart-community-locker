import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:scls/models/compartment.dart';
import 'package:scls/models/locker_station.dart';
import 'package:scls/models/reservation.dart';
import 'package:scls/repositories/in_memory_access_backend.dart';
import 'package:scls/repositories/in_memory_booking_repository.dart';
import 'package:scls/repositories/in_memory_locker_repository.dart';
import 'package:scls/viewmodels/access_view_model.dart';

/// The screen state for FR4 and FR5.
///
/// The clock is driven by hand here. Every assertion about the 120 second life
/// would otherwise take 120 seconds, and the boundary E4 cares about could not
/// be checked at all.
void main() {
  late InMemoryLockerRepository lockers;
  late InMemoryBookingRepository bookings;
  late InMemoryAccessBackend backend;
  late StreamController<DateTime> clock;
  late Reservation booking;

  const owner = 'U-OWNER';

  /// The fake present. Tests move it and then pump the clock stream.
  late DateTime fakeNow;

  setUp(() async {
    fakeNow = DateTime.utc(2026, 10, 6, 12, 0, 0);
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
    // The backend gets the same fake clock as the ViewModel. Giving them
    // different clocks is how the first run of this file failed: the server
    // minted a token dated by the real clock, the screen judged it by the fake
    // one, and every token looked expired the instant it was issued.
    backend = InMemoryAccessBackend(
      lockers: lockers,
      bookings: bookings,
      now: () => fakeNow,
    );
    clock = StreamController<DateTime>.broadcast();

    booking = await bookings.book(
      userId: owner,
      stationId: 'ST-1',
      compartmentId: 'C1',
      purpose: ReservationPurpose.parcel,
      end: DateTime.now().add(const Duration(hours: 2)),
    );
  });

  tearDown(() async {
    await clock.close();
    await backend.dispose();
  });

  AccessViewModel build() => AccessViewModel(
    tokens: backend,
    gateway: backend,
    reservation: booking,
    userId: owner,
    clock: clock.stream,
    now: () => fakeNow,
  );

  /// Moves the fake clock and lets the ViewModel notice.
  Future<void> advance(AccessViewModel vm, Duration by) async {
    fakeNow = fakeNow.add(by);
    clock.add(fakeNow);
    await Future<void>.delayed(Duration.zero);
  }

  group('initial state', () {
    test('starts with no code and nothing to show', () {
      final vm = build();
      addTearDown(vm.dispose);

      expect(vm.token, isNull);
      expect(vm.qrPayload, isNull);
      expect(vm.hasLiveToken, isFalse);
      expect(vm.remaining, Duration.zero);
      expect(vm.isBusy, isFalse);
      expect(vm.hasError, isFalse);
    });

    test('picks up the gateway connection state', () {
      backend.setConnected(false);
      final vm = build();
      addTearDown(vm.dispose);

      expect(vm.isOnline, isFalse);
    });
  });

  group('requesting a code (FR4)', () {
    test('produces a live token with a payload to draw', () async {
      final vm = build();
      addTearDown(vm.dispose);

      expect(await vm.requestToken(), isTrue);

      expect(vm.token, isNotNull);
      expect(vm.hasLiveToken, isTrue);
      expect(vm.qrPayload, isNotEmpty);
      expect(vm.hasError, isFalse);
    });

    test('a cancelled booking is refused with a message', () async {
      await bookings.cancel(booking.id);
      final vm = build();
      addTearDown(vm.dispose);

      expect(await vm.requestToken(), isFalse);

      expect(vm.token, isNull);
      expect(vm.error, contains('no longer active'));
    });

    test('is busy while the request is in flight', () async {
      final slow = InMemoryAccessBackend(
        lockers: lockers,
        bookings: bookings,
        delay: const Duration(milliseconds: 20),
        now: () => fakeNow,
      );
      addTearDown(slow.dispose);
      final vm = AccessViewModel(
        tokens: slow,
        gateway: slow,
        reservation: booking,
        userId: owner,
        clock: clock.stream,
        now: () => fakeNow,
      );
      addTearDown(vm.dispose);

      final future = vm.requestToken();
      expect(vm.isRequesting, isTrue);
      expect(vm.isBusy, isTrue);
      await future;
      expect(vm.isRequesting, isFalse);
    });
  });

  group('the countdown (E4: TTL 120 s)', () {
    test('starts at the full 120 seconds', () async {
      final vm = build();
      addTearDown(vm.dispose);
      await vm.requestToken();

      expect(vm.remaining.inSeconds, closeTo(120, 1));
      expect(vm.remainingFraction, closeTo(1.0, 0.01));
    });

    test('counts down as the clock moves', () async {
      final vm = build();
      addTearDown(vm.dispose);
      await vm.requestToken();

      await advance(vm, const Duration(seconds: 30));

      expect(vm.remaining.inSeconds, closeTo(90, 1));
      expect(vm.remainingFraction, closeTo(0.75, 0.02));
    });

    test('notifies on every tick, so the display moves', () async {
      final vm = build();
      addTearDown(vm.dispose);
      await vm.requestToken();

      var notifications = 0;
      vm.addListener(() => notifications++);

      await advance(vm, const Duration(seconds: 1));
      await advance(vm, const Duration(seconds: 1));

      expect(notifications, 2);
    });

    test('does not notify when there is no token to count down', () async {
      final vm = build();
      addTearDown(vm.dispose);

      var notifications = 0;
      vm.addListener(() => notifications++);
      await advance(vm, const Duration(seconds: 5));

      expect(notifications, 0, reason: 'nothing on screen is changing');
    });

    test('is still live one second before expiry', () async {
      final vm = build();
      addTearDown(vm.dispose);
      await vm.requestToken();

      await advance(vm, const Duration(seconds: 119));

      expect(vm.hasLiveToken, isTrue);
      expect(vm.qrPayload, isNotNull);
    });

    test('stops being live at 120 seconds', () async {
      final vm = build();
      addTearDown(vm.dispose);
      await vm.requestToken();

      await advance(vm, const Duration(seconds: 120));

      expect(vm.hasLiveToken, isFalse);
      expect(vm.hasExpiredToken, isTrue);
      expect(vm.remaining, Duration.zero);
    });

    test('an expired code stops being displayed', () async {
      // Leaving a dead QR code on screen invites the user to hold up something
      // that cannot work and wonder why the scanner is broken.
      final vm = build();
      addTearDown(vm.dispose);
      await vm.requestToken();

      await advance(vm, const Duration(seconds: 125));

      expect(vm.qrPayload, isNull);
      expect(vm.remainingFraction, 0);
    });

    test('a new request replaces an expired code', () async {
      final vm = build();
      addTearDown(vm.dispose);
      await vm.requestToken();
      final first = vm.token!.id;
      await advance(vm, const Duration(seconds: 125));

      await vm.requestToken();

      expect(vm.hasLiveToken, isTrue);
      expect(vm.token!.id, isNot(first));
    });
  });

  group('opening remotely (FR5)', () {
    test('a live code opens the locker', () async {
      final vm = build();
      addTearDown(vm.dispose);
      await vm.requestToken();

      expect(await vm.openRemotely(), isTrue);

      expect(vm.lastOutcome?.accepted, isTrue);
      expect(vm.hasError, isFalse);
    });

    test('the code is gone once it has worked', () async {
      final vm = build();
      addTearDown(vm.dispose);
      await vm.requestToken();
      await vm.openRemotely();

      expect(vm.token, isNull, reason: 'single use means single display');
      expect(vm.qrPayload, isNull);
    });

    test('opening with no code says so rather than failing silently', () async {
      final vm = build();
      addTearDown(vm.dispose);

      expect(await vm.openRemotely(), isFalse);
      expect(vm.error, 'Get a code first.');
    });

    test('the real door state arrives from the cabinet', () async {
      final vm = build();
      addTearDown(vm.dispose);
      await vm.requestToken();
      await vm.openRemotely();
      await Future<void>.delayed(Duration.zero);

      expect(vm.lastDoorEvent, isNotNull);
      expect(vm.doorIsOpen, isTrue);
      expect(vm.lastDoorEvent!.tokenId, isNotNull);
    });

    test('a faulty door is reported as such, not as a success', () async {
      // FR5 is about the real door state. A command that was accepted and a
      // door that moved are two different facts.
      final vm = build();
      addTearDown(vm.dispose);

      backend.reportDoorFaulty(stationId: 'ST-1', compartmentId: 'C1');
      await Future<void>.delayed(Duration.zero);

      expect(vm.lastDoorEvent?.isFaulty, isTrue);
      expect(vm.doorIsOpen, isFalse);
    });

    test('a replayed code is refused and cleared', () async {
      final vm = build();
      addTearDown(vm.dispose);
      await vm.requestToken();
      final payload = vm.qrPayload!;
      await vm.openRemotely();

      // Ask again with the same spent payload, as a replay would.
      final vm2 = build();
      addTearDown(vm2.dispose);
      final outcome = await backend.present(
        stationId: 'ST-1',
        compartmentId: 'C1',
        payload: payload,
      );

      expect(outcome.accepted, isFalse);
      expect(vm2.token, isNull);
    });
  });

  group('having no code is three different situations', () {
    // Found by reading a demo screenshot: the panel said "Ready when you are,
    // get a code" directly above "The door is open, opened with your code".
    // All three states leave hasLiveToken false, and the screen had one layout
    // for all of them.
    test('before anything is asked for, none of the three apply', () {
      final vm = build();
      addTearDown(vm.dispose);

      expect(vm.hasLiveToken, isFalse);
      expect(vm.codeWasUsed, isFalse);
      expect(vm.hasExpiredToken, isFalse);
    });

    test('a spent code is marked used, not merely absent', () async {
      final vm = build();
      addTearDown(vm.dispose);
      await vm.requestToken();
      await vm.openRemotely();

      expect(vm.hasLiveToken, isFalse);
      expect(vm.codeWasUsed, isTrue);
      expect(vm.hasExpiredToken, isFalse);
    });

    test('a timed-out code is expired, not used', () async {
      final vm = build();
      addTearDown(vm.dispose);
      await vm.requestToken();
      await advance(vm, const Duration(seconds: 125));

      expect(vm.hasExpiredToken, isTrue);
      expect(vm.codeWasUsed, isFalse);
    });

    test('a refused code is neither used nor merely absent', () async {
      final vm = build();
      addTearDown(vm.dispose);
      await vm.requestToken();
      backend.setConnected(false);
      await vm.openRemotely();

      expect(vm.codeWasUsed, isFalse, reason: 'it was refused, not spent');
      expect(vm.hasError, isTrue);
    });

    test('asking for a new code clears the used state', () async {
      final vm = build();
      addTearDown(vm.dispose);
      await vm.requestToken();
      await vm.openRemotely();
      expect(vm.codeWasUsed, isTrue);

      await vm.requestToken();

      expect(vm.codeWasUsed, isFalse);
      expect(vm.hasLiveToken, isTrue);
    });
  });

  group('the offline path (QR4)', () {
    test('going offline is reflected on the screen', () async {
      final vm = build();
      addTearDown(vm.dispose);

      backend.setConnected(false);
      await Future<void>.delayed(Duration.zero);

      expect(vm.isOnline, isFalse);
    });

    test('a token is refused while offline, pointing at the PIN', () async {
      final vm = build();
      addTearDown(vm.dispose);
      await vm.requestToken();
      backend.setConnected(false);

      expect(await vm.openRemotely(), isFalse);
      expect(vm.error, contains('backup PIN'));
    });

    test('the PIN opens the locker with no network', () async {
      final vm = build();
      addTearDown(vm.dispose);
      await vm.requestToken();
      final pin = vm.token!.fallbackPin!;
      backend.setConnected(false);

      expect(await vm.openWithPin(pin), isTrue);
      expect(vm.lastOutcome?.accepted, isTrue);
    });

    test('an empty PIN is caught before the gateway is called', () async {
      final vm = build();
      addTearDown(vm.dispose);

      expect(await vm.openWithPin('   '), isFalse);
      expect(vm.error, 'Enter your backup PIN.');
    });

    test('a wrong PIN is reported', () async {
      final vm = build();
      addTearDown(vm.dispose);
      await vm.requestToken();

      expect(await vm.openWithPin('0000'), anyOf(isTrue, isFalse));
      // The generated PIN could be 0000 one time in ten thousand, so assert on
      // a value that definitely is not it.
      final wrong = vm.token?.fallbackPin == '1234' ? '4321' : '1234';
      await vm.openWithPin(wrong);
      expect(vm.hasError, isTrue);
    });
  });

  group('the PIN is hidden by default', () {
    test('is not exposed until the user asks', () async {
      // This screen gets held up in a shared lobby. A 120 second QR code that
      // somebody photographs is worthless; a PIN that somebody reads over a
      // shoulder works for the rest of the booking.
      final vm = build();
      addTearDown(vm.dispose);
      await vm.requestToken();

      expect(vm.hasPin, isTrue);
      expect(vm.pin, isNull);
      expect(vm.isPinVisible, isFalse);
    });

    test('shows and hides on request', () async {
      final vm = build();
      addTearDown(vm.dispose);
      await vm.requestToken();

      vm.showPin();
      expect(vm.pin, isNotNull);
      expect(vm.pin, matches(RegExp(r'^\d{4}$')));

      vm.hidePin();
      expect(vm.pin, isNull);
    });

    test('hides again when a new code is requested', () async {
      final vm = build();
      addTearDown(vm.dispose);
      await vm.requestToken();
      vm.showPin();

      await vm.requestToken();

      expect(vm.isPinVisible, isFalse);
    });

    test('showing twice does not notify twice', () async {
      final vm = build();
      addTearDown(vm.dispose);
      await vm.requestToken();
      vm.showPin();

      var notifications = 0;
      vm.addListener(() => notifications++);
      vm.showPin();

      expect(notifications, 0);
    });
  });

  group('waiting on the door', () {
    test('an accepted code with no door report yet is still waiting', () async {
      // The honest intermediate state: the system asked and does not know yet.
      //
      // It needs a cabinet that takes time to report, because one that answers
      // instantly never passes through this state. The first version of this
      // test used the default backend and failed for exactly that reason: the
      // state being asserted could not occur.
      final slow = InMemoryAccessBackend(
        lockers: lockers,
        bookings: bookings,
        doorReportDelay: const Duration(milliseconds: 50),
        now: () => fakeNow,
      );
      addTearDown(slow.dispose);
      final vm = AccessViewModel(
        tokens: slow,
        gateway: slow,
        reservation: booking,
        userId: owner,
        clock: clock.stream,
        now: () => fakeNow,
      );
      addTearDown(vm.dispose);

      await vm.requestToken();
      await vm.openRemotely();

      expect(vm.lastOutcome?.accepted, isTrue);
      expect(vm.lastDoorEvent, isNull);
      expect(vm.awaitingDoor, isTrue);

      // And it stops waiting once the cabinet gets round to answering.
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(vm.awaitingDoor, isFalse);
      expect(vm.doorIsOpen, isTrue);
    });

    test('stops waiting once the cabinet reports', () async {
      final vm = build();
      addTearDown(vm.dispose);
      await vm.requestToken();
      await vm.openRemotely();
      await Future<void>.delayed(Duration.zero);

      expect(vm.awaitingDoor, isFalse);
      expect(vm.doorIsOpen, isTrue);
    });

    test('is not waiting when nothing has been presented', () {
      final vm = build();
      addTearDown(vm.dispose);

      expect(vm.awaitingDoor, isFalse);
    });
  });

  group('errors', () {
    test('clearError removes a message and notifies once', () async {
      final vm = build();
      addTearDown(vm.dispose);
      await vm.openRemotely();
      expect(vm.hasError, isTrue);

      var notifications = 0;
      vm.addListener(() => notifications++);
      vm.clearError();

      expect(vm.hasError, isFalse);
      expect(notifications, 1);
    });

    test('clearError is a no-op when there is nothing to clear', () {
      final vm = build();
      addTearDown(vm.dispose);

      var notifications = 0;
      vm.addListener(() => notifications++);
      vm.clearError();

      expect(notifications, 0);
    });
  });

  group('disposal', () {
    test('stops listening to the clock, the door and the connection', () async {
      final vm = build();
      await vm.requestToken();
      vm.dispose();

      // None of these may reach a disposed ChangeNotifier, which would throw.
      clock.add(fakeNow.add(const Duration(seconds: 1)));
      backend.setConnected(false);
      backend.reportDoorFaulty(stationId: 'ST-1', compartmentId: 'C1');
      await Future<void>.delayed(Duration.zero);
    });
  });
}
