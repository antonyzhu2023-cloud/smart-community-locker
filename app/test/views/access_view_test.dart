import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:scls/models/compartment.dart';
import 'package:scls/models/locker_station.dart';
import 'package:scls/models/reservation.dart';
import 'package:scls/repositories/in_memory_access_backend.dart';
import 'package:scls/repositories/in_memory_booking_repository.dart';
import 'package:scls/repositories/in_memory_locker_repository.dart';
import 'package:scls/viewmodels/access_view_model.dart';
import 'package:scls/views/access_view.dart';

/// Widget-level checks over the access screen (FR4, FR5).
///
/// This file exists because the screen did not have one. The ViewModel was
/// covered from the start and the screen was not, which left 170 lines of the
/// most important feature in the system unexercised, and the coverage figure
/// I had been quoting was measured before those lines existed.
///
/// What is checked here is specifically what a ViewModel test cannot see:
/// whether two correct pieces of state produce a screen that contradicts
/// itself. Three of the four defects that reached the demonstration
/// screenshots were of exactly that kind, and the regressions for them are the
/// tests named "does not also say" below.
void main() {
  late InMemoryLockerRepository lockers;
  late InMemoryBookingRepository bookings;
  late InMemoryAccessBackend backend;
  late StreamController<DateTime> clock;
  late Reservation booking;
  late DateTime fakeNow;

  const owner = 'U-OWNER';

  setUp(() async {
    // Anchored to the real clock, not to a fixed date.
    //
    // This was `DateTime.utc(2026, 10, 16, 12)` and every test in this file
    // passed on the day it was written and failed on the next one. The booking
    // repository validates the end time against the real clock, so a booking
    // two hours after a hard-coded yesterday is a booking in the past, and
    // setUp threw before any assertion ran. The fake clock is still fake: the
    // tests move it by hand. It just starts from a point that is always valid.
    fakeNow = DateTime.now().toUtc();
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
    // The backend and the screen share one fake clock. Giving them different
    // clocks makes every token look expired the instant it is issued.
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
      end: fakeNow.add(const Duration(hours: 2)),
    );
  });

  tearDown(() async {
    await clock.close();
    await backend.dispose();
  });

  AccessViewModel buildVm() => AccessViewModel(
    tokens: backend,
    gateway: backend,
    reservation: booking,
    userId: owner,
    clock: clock.stream,
    now: () => fakeNow,
  );

  /// Gives the test a surface tall enough to hold the whole screen.
  ///
  /// The default 800x600 test window cuts the access screen off below the door
  /// panel. A ListView does not build children it cannot show, so the PIN
  /// panel and the problem banner were not merely invisible to the eye, they
  /// were absent from the widget tree and every finder returned nothing. That
  /// is a property of the test harness rather than of the screen.
  void useTallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// Pumps the screen with a ViewModel the test can still reach.
  Future<AccessViewModel> show(WidgetTester tester) async {
    useTallSurface(tester);
    final vm = buildVm();
    addTearDown(vm.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider<AccessViewModel>.value(
          value: vm,
          child: AccessView(reservation: booking),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return vm;
  }

  Future<void> advance(WidgetTester tester, Duration by) async {
    fakeNow = fakeNow.add(by);
    clock.add(fakeNow);
    await tester.pumpAndSettle();
  }

  group('the code itself', () {
    testWidgets('asks for a code on open and shows the countdown', (
      tester,
    ) async {
      await show(tester);

      expect(find.text('seconds left'), findsOneWidget);
      expect(find.text('120'), findsOneWidget);
      expect(find.text('Open without scanning'), findsOneWidget);
    });

    testWidgets('the countdown follows the clock', (tester) async {
      await show(tester);
      await advance(tester, const Duration(seconds: 30));

      expect(find.text('90'), findsOneWidget);
      expect(find.text('120'), findsNothing);
    });

    testWidgets('the countdown turns red for the last fifteen seconds', (
      tester,
    ) async {
      await show(tester);

      Color? ringColour() => tester
          .widget<CircularProgressIndicator>(
            find.byType(CircularProgressIndicator),
          )
          .color;

      final scheme = Theme.of(tester.element(find.byType(AccessView)))
          .colorScheme;

      await advance(tester, const Duration(seconds: 100));
      expect(ringColour(), scheme.primary);

      await advance(tester, const Duration(seconds: 6));
      expect(
        ringColour(),
        scheme.error,
        reason:
            'under fifteen seconds, fetching a new code beats hurrying, and '
            'the screen should say which situation the user is in',
      );
    });
  });

  group('the three states with no live code', () {
    testWidgets('the screen asks for a code without being told to', (
      tester,
    ) async {
      final vm = await show(tester);

      expect(
        vm.hasLiveToken,
        isTrue,
        reason:
            'a user who opened this screen wants to open a locker, so making '
            'them press a button first is a step with no decision in it',
      );
    });

    testWidgets('an expired code says so, and does not also say "Ready"', (
      tester,
    ) async {
      await show(tester);
      await advance(tester, const Duration(seconds: 121));

      expect(find.text('That code has expired'), findsOneWidget);
      expect(find.text('Get a new code'), findsOneWidget);
      expect(find.text('Ready when you are'), findsNothing);
    });

    testWidgets('a used code says so, and does not also say "Ready"', (
      tester,
    ) async {
      final vm = await show(tester);
      await vm.openRemotely();
      await tester.pumpAndSettle();

      expect(find.text('Code used'), findsOneWidget);
      expect(find.text('Get another code'), findsOneWidget);
      expect(
        find.text('Ready when you are'),
        findsNothing,
        reason:
            'this is the regression for a defect that reached a demonstration '
            'screenshot: the prompt to get a first code sat directly above the '
            'confirmation that the door had already been opened',
      );
    });

    testWidgets('a used code and an open door do not contradict each other', (
      tester,
    ) async {
      final vm = await show(tester);
      await vm.openRemotely();
      await tester.pumpAndSettle();

      expect(find.text('Code used'), findsOneWidget);
      expect(find.text('The door is open'), findsOneWidget);
      expect(find.text('No report from the locker'), findsNothing);
    });
  });

  group('what the door reports', () {
    testWidgets('an accepted code with no door report yet says it is waiting', (
      tester,
    ) async {
      useTallSurface(tester);
      final backendWithDelay = InMemoryAccessBackend(
        lockers: lockers,
        bookings: bookings,
        now: () => fakeNow,
        doorReportDelay: const Duration(milliseconds: 200),
      );
      addTearDown(backendWithDelay.dispose);

      final vm = AccessViewModel(
        tokens: backendWithDelay,
        gateway: backendWithDelay,
        reservation: booking,
        userId: owner,
        clock: clock.stream,
        now: () => fakeNow,
      );
      addTearDown(vm.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<AccessViewModel>.value(
            value: vm,
            child: AccessView(reservation: booking),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await vm.openRemotely();
      await tester.pump();

      expect(find.text('Waiting for the locker'), findsOneWidget);
      expect(find.text('The door is open'), findsNothing);

      // Let the delayed report arrive so the test does not end with a pending
      // timer.
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.text('The door is open'), findsOneWidget);
    });

    testWidgets('an open door names the credential that opened it', (
      tester,
    ) async {
      final vm = await show(tester);
      await vm.openRemotely();
      await tester.pumpAndSettle();

      expect(find.text('Opened with your code.'), findsOneWidget);
      expect(find.text('Opened with your backup PIN.'), findsNothing);
    });

    testWidgets('a faulty door is not reported as open', (tester) async {
      await show(tester);

      backend.reportDoorFaulty(stationId: 'ST-1', compartmentId: 'C1');
      await tester.pumpAndSettle();

      expect(find.text('The door did not open'), findsOneWidget);
      expect(find.text('The door is open'), findsNothing);
      expect(
        find.textContaining('taken out of service'),
        findsOneWidget,
        reason: 'a jammed door needs a human, and the screen should say so',
      );
    });

    testWidgets('a closed door reports whether something is inside', (
      tester,
    ) async {
      await show(tester);

      backend.reportDoorClosed(
        stationId: 'ST-1',
        compartmentId: 'C1',
        itemInside: true,
      );
      await tester.pumpAndSettle();

      expect(find.text('The door is closed'), findsOneWidget);
      expect(find.text('Something is inside.'), findsOneWidget);
    });
  });

  group('the backup PIN', () {
    testWidgets('is hidden until it is asked for', (tester) async {
      final vm = await show(tester);
      final pin = vm.token?.fallbackPin;

      expect(pin, isNotNull);
      expect(find.text('Backup PIN'), findsOneWidget);
      expect(find.text('Show mine'), findsOneWidget);
      expect(find.text(pin!), findsNothing);
    });

    testWidgets('appears on request and can be hidden again', (tester) async {
      final vm = await show(tester);
      final pin = vm.token!.fallbackPin!;

      await tester.tap(find.text('Show mine'));
      await tester.pumpAndSettle();
      expect(find.text(pin), findsOneWidget);
      expect(find.text('Hide'), findsOneWidget);

      await tester.tap(find.text('Hide'));
      await tester.pumpAndSettle();
      expect(find.text(pin), findsNothing);
    });

    testWidgets('opens the locker and the door says it was the PIN', (
      tester,
    ) async {
      final vm = await show(tester);
      final pin = vm.token!.fallbackPin!;

      await tester.enterText(find.byType(TextField), pin);
      await tester.tap(find.text('Open with PIN'));
      await tester.pumpAndSettle();

      expect(find.text('The door is open'), findsOneWidget);
      expect(find.text('Opened with your backup PIN.'), findsOneWidget);
    });
  });

  group('banners', () {
    testWidgets('an offline gateway says the PIN still works', (tester) async {
      await show(tester);

      backend.setConnected(false);
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Your backup PIN still works'),
        findsOneWidget,
      );
    });

    testWidgets('a refused code shows a problem that can be dismissed', (
      tester,
    ) async {
      final vm = await show(tester);

      // A PIN that is definitely not this booking's PIN.
      final realPin = vm.token!.fallbackPin!;
      final wrongPin = realPin == '0000' ? '1111' : '0000';

      await vm.openWithPin(wrongPin);
      await tester.pumpAndSettle();

      expect(vm.hasError, isTrue);
      expect(find.byTooltip('Dismiss'), findsOneWidget);

      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pumpAndSettle();

      expect(vm.hasError, isFalse);
      expect(find.byTooltip('Dismiss'), findsNothing);
    });
  });
}
