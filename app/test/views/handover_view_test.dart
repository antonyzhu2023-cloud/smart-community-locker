import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:scls/models/app_user.dart';
import 'package:scls/models/compartment.dart';
import 'package:scls/models/locker_station.dart';
import 'package:scls/models/reservation.dart';
import 'package:scls/repositories/in_memory_access_backend.dart';
import 'package:scls/repositories/in_memory_auth_repository.dart';
import 'package:scls/repositories/in_memory_booking_repository.dart';
import 'package:scls/repositories/in_memory_locker_repository.dart';
import 'package:scls/viewmodels/handover_view_model.dart';
import 'package:scls/views/handover_view.dart';

/// Widget-level checks over the hand-over screen (FR7).
///
/// FR7 is the feature that makes this system different from a carrier locker,
/// and until this file was written it had no screen-level test at all. The
/// ViewModel was covered; the 141 lines that a resident actually looks at were
/// not.
///
/// The cases that matter most here are the ones about what the screen refuses
/// to say: that an unverified neighbour is reported the same way as a
/// non-existent one, and that a neighbour's own card offers one action rather
/// than three.
void main() {
  late InMemoryLockerRepository lockers;
  late InMemoryBookingRepository bookings;
  late InMemoryAuthRepository auth;
  late InMemoryAccessBackend backend;
  late Reservation booking;
  late AppUser owner;

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
    auth = InMemoryAuthRepository();
    addTearDown(auth.dispose);

    owner = await auth.register(
      email: 'mei@example.com',
      displayName: 'Mei Chen',
      password: 'password1',
      membershipCode: 'WG-1041',
    );
    // Registered so the account exists to be found. The returned user is not
    // needed: these tests look it up through the screen, the way the owner
    // does.
    await auth.register(
      email: 'tom@example.com',
      displayName: 'Tom Baker',
      password: 'password1',
      membershipCode: 'WG-1042',
    );

    bookings = InMemoryBookingRepository(lockers);
    backend = InMemoryAccessBackend(lockers: lockers, bookings: bookings);

    booking = await bookings.book(
      userId: owner.id,
      stationId: 'ST-1',
      compartmentId: 'C1',
      purpose: ReservationPurpose.handover,
      end: DateTime.now().add(const Duration(hours: 2)),
    );
  });

  tearDown(() async {
    await backend.dispose();
  });

  HandoverViewModel buildVm({Reservation? reservation}) => HandoverViewModel(
    tokens: backend,
    auth: auth,
    reservation: reservation ?? booking,
    ownerId: owner.id,
  );

  Future<HandoverViewModel> show(
    WidgetTester tester, {
    Reservation? reservation,
  }) async {
    // The default 800x600 test window cuts this screen off, and a ListView
    // does not build children it cannot show.
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final vm = buildVm(reservation: reservation);
    addTearDown(vm.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider<HandoverViewModel>.value(
          value: vm,
          child: HandoverView(reservation: reservation ?? booking),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return vm;
  }

  Future<void> findNeighbour(WidgetTester tester, String email) async {
    await tester.enterText(find.byType(TextField), email);
    await tester.tap(find.text('Find them'));
    await tester.pumpAndSettle();
  }

  group('the empty screen', () {
    testWidgets('names the compartment and explains what is given away', (
      tester,
    ) async {
      await show(tester);

      expect(find.text('Compartment C1'), findsOneWidget);
      expect(find.textContaining('You keep your own access'), findsOneWidget);
    });

    testWidgets('says plainly that nobody else has access yet', (tester) async {
      await show(tester);

      expect(find.text('Nobody else can open this locker.'), findsOneWidget);
      expect(find.text('Take back'), findsNothing);
    });

    testWidgets('a booking that can no longer be opened offers nothing', (
      tester,
    ) async {
      final cancelled = await bookings.cancel(booking.id);
      await show(tester, reservation: cancelled);

      expect(find.textContaining('no longer active'), findsOneWidget);
      expect(
        find.text('Find them'),
        findsNothing,
        reason:
            'the form is absent rather than present and refusing, so there is '
            'nothing to type into and nothing to be refused by',
      );
    });
  });

  group('finding a neighbour', () {
    testWidgets('shows who was found before anything is given away', (
      tester,
    ) async {
      await show(tester);
      await findNeighbour(tester, 'tom@example.com');

      expect(find.text('Tom Baker'), findsOneWidget);
      // A Text, not the EditableText still holding what was typed into the
      // search box. find.text matches both.
      expect(
        find.byWidgetPredicate((w) => w is Text && w.data == 'tom@example.com'),
        findsOneWidget,
      );
      expect(find.text('Give Tom access'), findsOneWidget);
    });

    testWidgets('an address with no account is refused', (tester) async {
      await show(tester);
      await findNeighbour(tester, 'nobody@example.com');

      expect(find.textContaining('No verified resident found'), findsOneWidget);
      expect(find.text('Give Tom access'), findsNothing);
    });

    testWidgets('an unverified account is refused in exactly the same words', (
      tester,
    ) async {
      await auth.register(
        email: 'unverified@example.com',
        displayName: 'Pat Unverified',
        password: 'password1',
      );

      await show(tester);
      await findNeighbour(tester, 'nobody@example.com');
      final missing = tester
          .widgetList<Text>(find.textContaining('No verified resident'))
          .first
          .data;

      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pumpAndSettle();
      await findNeighbour(tester, 'unverified@example.com');
      final unverified = tester
          .widgetList<Text>(find.textContaining('No verified resident'))
          .first
          .data;

      expect(
        unverified,
        missing,
        reason:
            'a different message would let this screen be used to find out '
            'who lives in the building',
      );
      expect(find.text('Pat Unverified'), findsNothing);
    });

    testWidgets('the owner cannot hand the locker to themselves', (
      tester,
    ) async {
      await show(tester);
      await findNeighbour(tester, 'mei@example.com');

      expect(find.textContaining('your own account'), findsOneWidget);
      expect(find.text('Give Mei access'), findsNothing);
    });

    testWidgets('an empty address asks for one rather than searching', (
      tester,
    ) async {
      await show(tester);
      await tester.tap(find.text('Find them'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Enter your neighbour'), findsOneWidget);
    });
  });

  group('handing over and taking back', () {
    testWidgets('a hand-over appears in the given-out list', (tester) async {
      await show(tester);
      await findNeighbour(tester, 'tom@example.com');

      await tester.tap(find.text('Give Tom access'));
      await tester.pumpAndSettle();

      expect(find.text('One code given out'), findsOneWidget);
      expect(find.text('Take back'), findsOneWidget);
      expect(find.text('Nobody else can open this locker.'), findsNothing);
      expect(find.textContaining('Tom Baker can now open'), findsOneWidget);
    });

    testWidgets('the search box is cleared so it cannot be handed twice', (
      tester,
    ) async {
      await show(tester);
      await findNeighbour(tester, 'tom@example.com');
      await tester.tap(find.text('Give Tom access'));
      await tester.pumpAndSettle();

      expect(find.text('Give Tom access'), findsNothing);
    });

    testWidgets('taking it back before use removes it', (tester) async {
      await show(tester);
      await findNeighbour(tester, 'tom@example.com');
      await tester.tap(find.text('Give Tom access'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Take back'));
      await tester.pumpAndSettle();

      expect(find.text('Take back'), findsNothing);
      expect(find.text('Nobody else can open this locker.'), findsOneWidget);
    });

    testWidgets('taking it back after use says so rather than pretending', (
      tester,
    ) async {
      final vm = await show(tester);
      await findNeighbour(tester, 'tom@example.com');
      await tester.tap(find.text('Give Tom access'));
      await tester.pumpAndSettle();

      // The neighbour redeems the hand-over for a code of their own and opens
      // the locker with that. The hand-over itself is a permission and cannot
      // be presented, which is the distinction the 24 October end-to-end run
      // showed was missing.
      final grant = vm.liveHandovers.single;
      final theirs = await backend.issue(
        reservationId: grant.reservationId,
        userId: grant.delegatedTo!,
      );
      await backend.present(
        stationId: booking.stationId,
        compartmentId: booking.compartmentId,
        payload: theirs.signedPayload,
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Take back'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('already been used'),
        findsOneWidget,
        reason:
            'FR7 says a hand-over is revocable before use. Reporting success '
            'afterwards would tell the owner the locker was never opened',
      );
    });
  });

  group('messages', () {
    testWidgets('an error can be dismissed', (tester) async {
      await show(tester);
      await findNeighbour(tester, 'nobody@example.com');

      expect(find.byTooltip('Dismiss'), findsOneWidget);
      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pumpAndSettle();

      expect(find.textContaining('No verified resident'), findsNothing);
    });
  });
}
