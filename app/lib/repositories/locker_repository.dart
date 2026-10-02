import '../models/locker_station.dart';

/// Where station and compartment data comes from.
///
/// This interface is the seam that the whole design in Milestone 1 rests on.
/// Nothing above it knows whether the data arrives from Firestore, from the
/// local cache, or from a fake built for a test. Two things depend on that:
///
///  * QR6, the 70% coverage target. ViewModels are tested against a fake
///    implementation of this interface, with no Firebase and no network.
///  * QR4, the offline mode. Falling back to cached data is a change inside an
///    implementation of this interface, not a change to any screen.
abstract class LockerRepository {
  /// All stations the user can see. Out of service compartments are included
  /// in the objects; filtering them for display is the ViewModel's job.
  Future<List<LockerStation>> fetchStations();

  Future<LockerStation?> fetchStation(String id);
}

/// Thrown when the underlying data source fails. Keeps Firestore and MQTT
/// exception types from leaking above the repository layer.
class LockerRepositoryException implements Exception {
  const LockerRepositoryException(this.message);
  final String message;

  @override
  String toString() => 'LockerRepositoryException: $message';
}
