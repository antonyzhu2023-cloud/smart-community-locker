import 'package:flutter_test/flutter_test.dart';
import 'package:scls/models/compartment.dart';
import 'package:scls/models/locker_station.dart';

void main() {
  Compartment c(String id, SizeClass size, CompartmentState state) =>
      Compartment(id: id, size: size, state: state);

  LockerStation build({
    StationStatus status = StationStatus.online,
    List<Compartment>? compartments,
  }) {
    return LockerStation(
      id: 'STATION-01',
      name: 'Test Station',
      latitude: -36.8536,
      longitude: 174.7657,
      status: status,
      compartments:
          compartments ??
          [
            c('A1', SizeClass.small, CompartmentState.free),
            c('A2', SizeClass.small, CompartmentState.occupied),
            c('B1', SizeClass.medium, CompartmentState.free),
            c('B2', SizeClass.medium, CompartmentState.reserved),
            c('C1', SizeClass.large, CompartmentState.outOfService),
            c('C2', SizeClass.large, CompartmentState.overdue),
          ],
    );
  }

  group('Compartment', () {
    test('only free counts as available', () {
      expect(
        c('x', SizeClass.small, CompartmentState.free).isAvailable,
        isTrue,
      );
      for (final state in [
        CompartmentState.reserved,
        CompartmentState.occupied,
        CompartmentState.overdue,
        CompartmentState.outOfService,
      ]) {
        expect(
          c('x', SizeClass.small, state).isAvailable,
          isFalse,
          reason: '$state must not be bookable',
        );
      }
    });

    test('only out of service is hidden', () {
      expect(
        c('x', SizeClass.small, CompartmentState.outOfService).isVisible,
        isFalse,
      );
      expect(
        c('x', SizeClass.small, CompartmentState.overdue).isVisible,
        isTrue,
      );
    });

    test('equality is by value, so lists compare cleanly in tests', () {
      expect(
        c('A1', SizeClass.small, CompartmentState.free),
        c('A1', SizeClass.small, CompartmentState.free),
      );
      expect(
        c('A1', SizeClass.small, CompartmentState.free),
        isNot(c('A1', SizeClass.small, CompartmentState.occupied)),
      );
    });
  });

  group('availableCompartments', () {
    test('counts only free doors, and excludes out of service', () {
      final station = build();
      expect(station.freeCount, 2);
      expect(station.availableCompartments.map((c) => c.id), ['A1', 'B1']);
    });
  });

  group('availableOfSize', () {
    test('filters by size and by availability together', () {
      final station = build();
      expect(station.availableOfSize(SizeClass.small).map((c) => c.id), ['A1']);
      expect(station.availableOfSize(SizeClass.medium).map((c) => c.id), [
        'B1',
      ]);
      // Both large doors are unusable, so the large filter returns nothing.
      expect(station.availableOfSize(SizeClass.large), isEmpty);
    });
  });

  group('isBookable', () {
    test('an online station with free doors is bookable', () {
      expect(build().isBookable, isTrue);
    });

    test('an offline station is not bookable even with free doors', () {
      // The controller cannot be reached, so an open command would never
      // arrive. Showing it as bookable would break FR5.
      expect(build(status: StationStatus.offline).isBookable, isFalse);
    });

    test('a full station is not bookable', () {
      final full = build(
        compartments: [c('A1', SizeClass.small, CompartmentState.occupied)],
      );
      expect(full.isBookable, isFalse);
    });

    test('a station with only out of service doors is not bookable', () {
      final broken = build(
        compartments: [c('A1', SizeClass.small, CompartmentState.outOfService)],
      );
      expect(broken.isBookable, isFalse);
    });
  });

  test('copyWith taking a station offline keeps its compartments', () {
    final original = build();
    final offline = original.copyWith(status: StationStatus.offline);

    expect(offline.status, StationStatus.offline);
    expect(offline.compartments, original.compartments);
    expect(offline.name, original.name);
  });
}
