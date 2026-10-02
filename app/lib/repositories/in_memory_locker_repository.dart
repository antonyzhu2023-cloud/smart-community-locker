import '../models/compartment.dart';
import '../models/locker_station.dart';
import 'locker_repository.dart';

/// A [LockerRepository] backed by three hard-coded stations.
///
/// Used for two things:
///
///  * Development before the Firestore collections exist, so the UI can be
///    built and screenshotted without a backend.
///  * A stand-in during widget tests.
///
/// It will be replaced by `FirestoreLockerRepository` in Sprint 1. Nothing
/// above this layer changes when that happens, which is the point of the
/// repository interface.
class InMemoryLockerRepository implements LockerRepository {
  InMemoryLockerRepository({List<LockerStation>? stations, this.delay})
    : _stations = stations ?? _seed();

  final List<LockerStation> _stations;

  /// Lets a test or a demo simulate a slow network.
  final Duration? delay;

  static List<LockerStation> _seed() {
    return [
      LockerStation(
        id: 'STATION-01',
        name: 'WG Building Lobby',
        latitude: -36.8536,
        longitude: 174.7657,
        status: StationStatus.online,
        compartments: [
          const Compartment(
            id: 'S1-A1',
            size: SizeClass.small,
            state: CompartmentState.free,
          ),
          const Compartment(
            id: 'S1-A2',
            size: SizeClass.small,
            state: CompartmentState.occupied,
          ),
          const Compartment(
            id: 'S1-B1',
            size: SizeClass.medium,
            state: CompartmentState.free,
          ),
          const Compartment(
            id: 'S1-C1',
            size: SizeClass.large,
            state: CompartmentState.outOfService,
          ),
        ],
      ),
      LockerStation(
        id: 'STATION-02',
        name: 'Student Hub Ground Floor',
        latitude: -36.8531,
        longitude: 174.7669,
        status: StationStatus.online,
        compartments: [
          const Compartment(
            id: 'S2-A1',
            size: SizeClass.small,
            state: CompartmentState.reserved,
          ),
          const Compartment(
            id: 'S2-B1',
            size: SizeClass.medium,
            state: CompartmentState.free,
          ),
          const Compartment(
            id: 'S2-B2',
            size: SizeClass.medium,
            state: CompartmentState.free,
          ),
        ],
      ),
      LockerStation(
        id: 'STATION-03',
        name: 'Hostel Mail Room',
        latitude: -36.8558,
        longitude: 174.7630,
        status: StationStatus.offline,
        compartments: [
          const Compartment(
            id: 'S3-A1',
            size: SizeClass.small,
            state: CompartmentState.free,
          ),
        ],
      ),
    ];
  }

  Future<void> _wait() async {
    if (delay != null) await Future<void>.delayed(delay!);
  }

  @override
  Future<List<LockerStation>> fetchStations() async {
    await _wait();
    return List.unmodifiable(_stations);
  }

  @override
  Future<LockerStation?> fetchStation(String id) async {
    await _wait();
    for (final station in _stations) {
      if (station.id == id) return station;
    }
    return null;
  }
}
