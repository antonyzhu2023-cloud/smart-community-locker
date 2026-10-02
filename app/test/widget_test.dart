import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:scls/models/compartment.dart';
import 'package:scls/models/locker_station.dart';
import 'package:scls/repositories/locker_repository.dart';
import 'package:scls/viewmodels/station_list_view_model.dart';
import 'package:scls/views/station_list_view.dart';

import 'fakes/fake_locker_repository.dart';

/// A thin smoke test over the station list screen.
///
/// Most of the behaviour is covered in the ViewModel tests, which run far
/// faster. This file only checks that the View is wired to the ViewModel at all,
/// that the three screen states render, and that the filter chips reach the
/// ViewModel. It is the widget-level safety net, not the main test effort.
void main() {
  Widget wrap(FakeLockerRepository repo) {
    return MultiProvider(
      providers: [
        Provider<LockerRepository>.value(value: repo),
        ChangeNotifierProvider<StationListViewModel>(
          create: (_) => StationListViewModel(repo),
        ),
      ],
      child: const MaterialApp(home: StationListView()),
    );
  }

  testWidgets('loads and lists the stations', (tester) async {
    final repo = FakeLockerRepository(
      stations: [
        station('A', compartments: [free('A-s1', SizeClass.small)]),
        station('B', compartments: [free('B-m1', SizeClass.medium)]),
      ],
    );

    await tester.pumpWidget(wrap(repo));
    await tester.pumpAndSettle();

    expect(find.text('Nearby lockers'), findsOneWidget);
    expect(find.text('Station A'), findsOneWidget);
    expect(find.text('Station B'), findsOneWidget);
  });

  testWidgets('shows the error state and can retry', (tester) async {
    final repo = FakeLockerRepository(
      error: const LockerRepositoryException('Station index unavailable.'),
    );

    await tester.pumpWidget(wrap(repo));
    await tester.pumpAndSettle();

    expect(find.text('Could not load stations'), findsOneWidget);
    expect(find.text('Station index unavailable.'), findsOneWidget);

    repo.error = null;
    repo.stations = [
      station('A', compartments: [free('A-s1', SizeClass.small)]),
    ];
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(find.text('Station A'), findsOneWidget);
  });

  testWidgets('shows the empty state when nothing matches', (tester) async {
    final repo = FakeLockerRepository(stations: const []);

    await tester.pumpWidget(wrap(repo));
    await tester.pumpAndSettle();

    expect(find.text('No free compartments'), findsOneWidget);
  });

  testWidgets('an offline station shows no free count', (tester) async {
    // Found by inspection on the emulator: the tile printed a stale free count
    // next to "Station offline", which reads as though the locker is usable.
    final repo = FakeLockerRepository(
      stations: [
        station(
          'OFF',
          status: StationStatus.offline,
          compartments: [free('OFF-s1', SizeClass.small)],
        ),
      ],
    );

    await tester.pumpWidget(wrap(repo));
    await tester.pumpAndSettle();

    expect(find.text('Station offline'), findsOneWidget);
    expect(find.text('--'), findsOneWidget);
    expect(find.text('1'), findsNothing);
  });

  testWidgets('tapping a size chip filters the list', (tester) async {
    final repo = FakeLockerRepository(
      stations: [
        station('A', compartments: [free('A-s1', SizeClass.small)]),
        station('B', compartments: [free('B-l1', SizeClass.large)]),
      ],
    );

    await tester.pumpWidget(wrap(repo));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Large'));
    await tester.pumpAndSettle();

    expect(find.text('Station B'), findsOneWidget);
    expect(find.text('Station A'), findsNothing);
  });
}
