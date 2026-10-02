import 'package:scls/models/compartment.dart';
import 'package:scls/models/locker_station.dart';
import 'package:scls/repositories/locker_repository.dart';

/// A hand-written test double for [LockerRepository].
///
/// A mock library (mocktail) is also available, but a hand-written fake is used
/// for this interface because the tests need to control two things a stubbed
/// call does not express well: how many times the repository was asked, and
/// what kind of failure it produces. Those are the two behaviours that matter
/// to `StationListViewModel`.
class FakeLockerRepository implements LockerRepository {
  FakeLockerRepository({this.stations = const [], this.error});

  List<LockerStation> stations;

  /// When set, [fetchStations] throws this instead of returning.
  Object? error;

  int fetchStationsCalls = 0;
  int fetchStationCalls = 0;

  @override
  Future<List<LockerStation>> fetchStations() async {
    fetchStationsCalls++;
    if (error != null) throw error!;
    return stations;
  }

  @override
  Future<LockerStation?> fetchStation(String id) async {
    fetchStationCalls++;
    if (error != null) throw error!;
    for (final station in stations) {
      if (station.id == id) return station;
    }
    return null;
  }
}

/// Builds a station with the compartment states a test asks for.
LockerStation station(
  String id, {
  StationStatus status = StationStatus.online,
  List<Compartment> compartments = const [],
}) {
  return LockerStation(
    id: id,
    name: 'Station $id',
    latitude: -36.85,
    longitude: 174.76,
    status: status,
    compartments: compartments,
  );
}

Compartment free(String id, SizeClass size) =>
    Compartment(id: id, size: size, state: CompartmentState.free);

Compartment taken(String id, SizeClass size) =>
    Compartment(id: id, size: size, state: CompartmentState.occupied);
