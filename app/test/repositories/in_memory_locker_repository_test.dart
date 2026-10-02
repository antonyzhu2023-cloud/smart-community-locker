import 'package:flutter_test/flutter_test.dart';
import 'package:scls/models/compartment.dart';
import 'package:scls/models/locker_station.dart';
import 'package:scls/repositories/in_memory_locker_repository.dart';

import '../fakes/fake_locker_repository.dart';

void main() {
  group('seeded data', () {
    test('returns the three seeded stations', () async {
      final repo = InMemoryLockerRepository();
      final stations = await repo.fetchStations();

      expect(stations, hasLength(3));
      expect(stations.map((s) => s.id), [
        'STATION-01',
        'STATION-02',
        'STATION-03',
      ]);
    });

    test('the seed includes an offline station and an out of service door', () {
      // The seed is deliberately mixed. If every station were healthy the empty
      // and disabled states in the UI would never be exercised by hand.
      final repo = InMemoryLockerRepository();
      return repo.fetchStations().then((stations) {
        expect(stations.any((s) => s.status == StationStatus.offline), isTrue);
        expect(
          stations.any(
            (s) => s.compartments.any(
              (c) => c.state == CompartmentState.outOfService,
            ),
          ),
          isTrue,
        );
      });
    });

    test('the returned list cannot be modified by the caller', () async {
      // A repository hands out data, not control of its own state.
      final repo = InMemoryLockerRepository();
      final stations = await repo.fetchStations();

      expect(() => stations.add(station('X')), throwsUnsupportedError);
    });
  });

  group('fetchStation', () {
    test('finds a station by id', () async {
      final repo = InMemoryLockerRepository();
      final found = await repo.fetchStation('STATION-02');

      expect(found, isNotNull);
      expect(found!.name, 'Student Hub Ground Floor');
    });

    test('returns null for an unknown id rather than throwing', () async {
      final repo = InMemoryLockerRepository();
      expect(await repo.fetchStation('STATION-99'), isNull);
    });
  });

  group('injected stations', () {
    test('a caller can replace the seed entirely', () async {
      final repo = InMemoryLockerRepository(
        stations: [
          station('ONLY-ONE', compartments: [free('A1', SizeClass.small)]),
        ],
      );

      final stations = await repo.fetchStations();
      expect(stations, hasLength(1));
      expect(stations.single.freeCount, 1);
    });

    test('an empty station list is allowed', () async {
      final repo = InMemoryLockerRepository(stations: const []);
      expect(await repo.fetchStations(), isEmpty);
      expect(await repo.fetchStation('STATION-01'), isNull);
    });
  });

  group('delay', () {
    test('the optional delay is applied to both reads', () async {
      final repo = InMemoryLockerRepository(
        delay: const Duration(milliseconds: 30),
      );

      final watch = Stopwatch()..start();
      await repo.fetchStations();
      await repo.fetchStation('STATION-01');
      watch.stop();

      // Two reads of 30 ms each. A loose bound keeps this from being flaky on
      // a loaded CI runner.
      expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(50));
    });

    test('no delay by default', () {
      expect(InMemoryLockerRepository().delay, isNull);
    });
  });
}
