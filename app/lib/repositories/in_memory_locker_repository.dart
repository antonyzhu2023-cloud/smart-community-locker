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
    // Copied into a mutable list: booking changes compartment states in place,
    // and a caller may well pass a const list.
    : _stations = List.of(stations ?? _seed());

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

  // ---------------------------------------------------------------------
  // Synchronous access used by InMemoryBookingRepository.
  //
  // These are not on the LockerRepository interface. Booking has to read a
  // compartment's state and change it with nothing in between, so these cannot
  // be futures: an await would open the very window that evaluation criterion
  // E3 says must not exist. In the Firebase build the same guarantee comes from
  // a Firestore transaction instead, which is why it does not appear on the
  // interface the rest of the app uses.
  // ---------------------------------------------------------------------

  LockerStation? stationById(String id) {
    for (final station in _stations) {
      if (station.id == id) return station;
    }
    return null;
  }

  Compartment? compartmentById(String stationId, String compartmentId) {
    final station = stationById(stationId);
    if (station == null) return null;
    for (final compartment in station.compartments) {
      if (compartment.id == compartmentId) return compartment;
    }
    return null;
  }

  /// Replaces one compartment's state in place. Returns false if the station or
  /// the compartment does not exist.
  bool setCompartmentState(
    String stationId,
    String compartmentId,
    CompartmentState state,
  ) {
    for (var i = 0; i < _stations.length; i++) {
      final station = _stations[i];
      if (station.id != stationId) continue;

      final updated = <Compartment>[];
      var found = false;
      for (final compartment in station.compartments) {
        if (compartment.id == compartmentId) {
          found = true;
          updated.add(compartment.copyWith(state: state));
        } else {
          updated.add(compartment);
        }
      }
      if (!found) return false;

      _stations[i] = station.copyWith(compartments: updated);
      return true;
    }
    return false;
  }

  /// The next free compartment of the same size at the same station, excluding
  /// [exceptId]. Used to offer an alternative when a booking loses a race.
  Compartment? nextFreeOfSameSize(
    String stationId,
    SizeClass size, {
    String? exceptId,
  }) {
    final station = stationById(stationId);
    if (station == null) return null;
    for (final compartment in station.availableOfSize(size)) {
      if (compartment.id != exceptId) return compartment;
    }
    return null;
  }
}
