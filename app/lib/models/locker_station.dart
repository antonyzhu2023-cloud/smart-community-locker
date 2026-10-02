import 'compartment.dart';

enum StationStatus { online, offline }

/// A physical cabinet at a community site. Composed of one or more
/// [Compartment]s, as in the Milestone 1 domain model (Figure 8).
class LockerStation {
  const LockerStation({
    required this.id,
    required this.name,
    required this.latitude,
    required this.longitude,
    required this.status,
    required this.compartments,
  });

  final String id;
  final String name;
  final double latitude;
  final double longitude;
  final StationStatus status;
  final List<Compartment> compartments;

  /// Compartments a user could actually book right now. Out of service doors
  /// are excluded, not just the occupied ones.
  List<Compartment> get availableCompartments =>
      compartments.where((c) => c.isAvailable).toList(growable: false);

  List<Compartment> availableOfSize(SizeClass size) => compartments
      .where((c) => c.isAvailable && c.size == size)
      .toList(growable: false);

  int get freeCount => availableCompartments.length;

  /// A station with no free doors, or whose controller is offline, is shown
  /// but cannot be booked.
  bool get isBookable => status == StationStatus.online && freeCount > 0;

  LockerStation copyWith({
    StationStatus? status,
    List<Compartment>? compartments,
  }) {
    return LockerStation(
      id: id,
      name: name,
      latitude: latitude,
      longitude: longitude,
      status: status ?? this.status,
      compartments: compartments ?? this.compartments,
    );
  }

  @override
  String toString() => 'LockerStation($id, $name, free=$freeCount)';
}
