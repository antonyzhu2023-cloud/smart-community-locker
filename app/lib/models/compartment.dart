/// A single lockable door inside a station.
///
/// The state machine comes from Milestone 1 (Figure 10). The important rule is
/// that a compartment only becomes [CompartmentState.occupied] after the door
/// has been closed with an item inside. That is why the design needs a door
/// sensor: without one the system cannot tell a booking apart from a real item.
library;

enum SizeClass { small, medium, large }

enum CompartmentState {
  /// Can be booked.
  free,

  /// Held for one user, not yet opened.
  reserved,

  /// Contains an item.
  occupied,

  /// Still occupied after the booked time ended. A fee is accruing.
  overdue,

  /// Door sensor fault, or the controller has been offline too long.
  /// Hidden from the station list so nobody books a locker that cannot open.
  outOfService,
}

class Compartment {
  const Compartment({
    required this.id,
    required this.size,
    required this.state,
  });

  final String id;
  final SizeClass size;
  final CompartmentState state;

  /// Only a free compartment can be booked. Reserved and occupied are both
  /// held by someone else, and out of service cannot be opened at all.
  bool get isAvailable => state == CompartmentState.free;

  /// Out of service compartments are not shown to users at all.
  bool get isVisible => state != CompartmentState.outOfService;

  Compartment copyWith({SizeClass? size, CompartmentState? state}) {
    return Compartment(
      id: id,
      size: size ?? this.size,
      state: state ?? this.state,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Compartment &&
      other.id == id &&
      other.size == size &&
      other.state == state;

  @override
  int get hashCode => Object.hash(id, size, state);

  @override
  String toString() => 'Compartment($id, ${size.name}, ${state.name})';
}
