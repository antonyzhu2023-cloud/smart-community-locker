import 'package:flutter_test/flutter_test.dart';
import 'package:scls/models/compartment.dart';
import 'package:scls/models/locker_station.dart';
import 'package:scls/repositories/locker_repository.dart';
import 'package:scls/viewmodels/station_list_view_model.dart';

import '../fakes/fake_locker_repository.dart';

/// The ViewModel is built directly with a fake repository. There is no widget,
/// no Firebase and no network in this file. That is the whole argument for MVVM
/// made in Milestone 1, and it is what makes the QR6 coverage target reachable.
void main() {
  late FakeLockerRepository repo;
  late StationListViewModel vm;

  setUp(() {
    repo = FakeLockerRepository(
      stations: [
        station(
          'A',
          compartments: [
            free('A-s1', SizeClass.small),
            free('A-m1', SizeClass.medium),
            taken('A-m2', SizeClass.medium),
          ],
        ),
        station('B', compartments: [free('B-l1', SizeClass.large)]),
        station('C', compartments: [taken('C-s1', SizeClass.small)]),
      ],
    );
    vm = StationListViewModel(repo);
  });

  group('initial state', () {
    test('starts idle, empty and without an error', () {
      expect(vm.isLoading, isFalse);
      expect(vm.hasError, isFalse);
      expect(vm.error, isNull);
      expect(vm.stations, isEmpty);
      expect(vm.sizeFilter, isNull);
    });

    test('is reported as empty before anything is loaded', () {
      expect(vm.isEmpty, isTrue);
    });
  });

  group('load', () {
    test('fetches once and exposes the stations', () async {
      await vm.load();

      expect(repo.fetchStationsCalls, 1);
      expect(vm.stations, hasLength(3));
      expect(vm.isLoading, isFalse);
      expect(vm.hasError, isFalse);
    });

    test('notifies twice: once on start, once on finish', () async {
      var notifications = 0;
      vm.addListener(() => notifications++);

      await vm.load();

      // The first notification drives the spinner, the second the list. A test
      // like this is cheap insurance against the spinner never appearing.
      expect(notifications, 2);
    });

    test('is loading while the fetch is in flight', () async {
      final future = vm.load();
      expect(vm.isLoading, isTrue);
      await future;
      expect(vm.isLoading, isFalse);
    });

    test('totalFreeCompartments sums only free doors', () async {
      await vm.load();
      // A has 2 free, B has 1, C has 0.
      expect(vm.totalFreeCompartments, 3);
    });

    test('is not empty when stations came back', () async {
      await vm.load();
      expect(vm.isEmpty, isFalse);
    });

    test('is empty when the source has no stations', () async {
      repo.stations = const [];
      await vm.load();

      expect(vm.isEmpty, isTrue);
      expect(vm.hasError, isFalse);
    });
  });

  group('error handling', () {
    test('a repository exception becomes the message the user sees', () async {
      repo.error = const LockerRepositoryException(
        'Station index unavailable.',
      );

      await vm.load();

      expect(vm.hasError, isTrue);
      expect(vm.error, 'Station index unavailable.');
      expect(vm.stations, isEmpty);
      expect(vm.isLoading, isFalse);
    });

    test(
      'an unexpected error becomes a readable message, not a stack trace',
      () async {
        // Anything that escapes the repository layer must still not reach the
        // screen raw. QR5 also means internal details are not shown to users.
        repo.error = StateError('FirebaseException: permission-denied');

        await vm.load();

        expect(vm.hasError, isTrue);
        expect(vm.error, contains('Could not load stations'));
        expect(vm.error, isNot(contains('permission-denied')));
      },
    );

    test('load never throws, so the View needs no try block', () async {
      repo.error = Exception('boom');
      await expectLater(vm.load(), completes);
    });

    test('a later successful load clears the error', () async {
      repo.error = const LockerRepositoryException('offline');
      await vm.load();
      expect(vm.hasError, isTrue);

      repo.error = null;
      await vm.load();

      expect(vm.hasError, isFalse);
      expect(vm.error, isNull);
      expect(vm.stations, hasLength(3));
    });

    test('is not reported as empty while an error is showing', () async {
      // Otherwise the user would see "no lockers here" when the real problem is
      // the network. Two different messages, two different actions.
      repo.error = const LockerRepositoryException('offline');
      await vm.load();

      expect(vm.isEmpty, isFalse);
      expect(vm.hasError, isTrue);
    });
  });

  group('size filter', () {
    test('keeps only stations with a free door of that size', () async {
      await vm.load();

      vm.setSizeFilter(SizeClass.small);
      expect(vm.stations.map((s) => s.id), ['A']);

      vm.setSizeFilter(SizeClass.medium);
      expect(vm.stations.map((s) => s.id), ['A']);

      vm.setSizeFilter(SizeClass.large);
      expect(vm.stations.map((s) => s.id), ['B']);
    });

    test('ignores occupied doors of the right size', () async {
      await vm.load();
      vm.setSizeFilter(SizeClass.small);

      // Station C has a small compartment, but it is occupied.
      expect(vm.stations.map((s) => s.id), isNot(contains('C')));
    });

    test('null clears the filter', () async {
      await vm.load();
      vm.setSizeFilter(SizeClass.large);
      expect(vm.stations, hasLength(1));

      vm.setSizeFilter(null);
      expect(vm.stations, hasLength(3));
      expect(vm.sizeFilter, isNull);
    });

    test('totalFreeCompartments respects the filter', () async {
      await vm.load();
      vm.setSizeFilter(SizeClass.large);
      expect(vm.totalFreeCompartments, 1);
    });

    test('notifies when the filter changes', () async {
      await vm.load();
      var notifications = 0;
      vm.addListener(() => notifications++);

      vm.setSizeFilter(SizeClass.small);
      expect(notifications, 1);
    });

    test(
      'does not notify when the filter is set to its current value',
      () async {
        await vm.load();
        vm.setSizeFilter(SizeClass.small);

        var notifications = 0;
        vm.addListener(() => notifications++);
        vm.setSizeFilter(SizeClass.small);

        // A needless notifyListeners() rebuilds the whole list for nothing.
        expect(notifications, 0);
      },
    );

    test('a filter that matches nothing reports empty, not an error', () async {
      repo.stations = [
        station('D', compartments: [free('D-s1', SizeClass.small)]),
      ];
      await vm.load();

      vm.setSizeFilter(SizeClass.large);

      expect(vm.stations, isEmpty);
      expect(vm.isEmpty, isTrue);
      expect(vm.hasError, isFalse);
    });

    test('the filter survives a reload', () async {
      await vm.load();
      vm.setSizeFilter(SizeClass.large);

      await vm.load();

      expect(vm.sizeFilter, SizeClass.large);
      expect(vm.stations.map((s) => s.id), ['B']);
    });

    test('an offline station is still listed, but is not bookable', () async {
      // FR2 shows nearby stations. FR5 cannot open a door at a station whose
      // controller is unreachable, so the list shows it and disables it rather
      // than hiding it, which would look like the locker had disappeared.
      repo.stations = [
        station(
          'OFF',
          status: StationStatus.offline,
          compartments: [free('OFF-s1', SizeClass.small)],
        ),
      ];
      await vm.load();

      expect(vm.stations, hasLength(1));
      expect(vm.stations.single.isBookable, isFalse);
    });
  });
}
