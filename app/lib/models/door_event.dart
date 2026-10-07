/// What the cabinet reports about a physical door.
///
/// FR5 says the app must show the *real* door state, not what the app asked
/// for. The two can differ: a command can be published and the door can still
/// fail to open because the solenoid jammed or the cabinet lost power between
/// receiving and acting. A system that assumes success is a system that tells
/// the user their parcel is accessible when it is locked in.
library;

enum DoorState {
  /// The sensor says the door is shut.
  closed,

  /// The sensor says the door is open.
  open,

  /// The command arrived but the door did not move within the timeout. The
  /// compartment goes out of service and someone has to look at it.
  faulty,
}

/// Why the door moved. Used for the audit trail required by QR5, where every
/// open has to be attributable.
enum DoorTrigger {
  /// Opened by a valid scanned or remotely presented token.
  token,

  /// Opened by the offline backup PIN (QR4).
  pin,

  /// Opened by a building manager, out of band.
  manual,

  /// Closed by the user, no command involved.
  userClosed,
}

class DoorEvent {
  const DoorEvent({
    required this.stationId,
    required this.compartmentId,
    required this.state,
    required this.at,
    this.trigger,
    this.tokenId,
    this.itemInside = false,
  });

  final String stationId;
  final String compartmentId;
  final DoorState state;
  final DateTime at;

  /// Null for an unprompted close.
  final DoorTrigger? trigger;

  /// Which token caused this, when one did. Carried so a repeated MQTT
  /// delivery can be recognised as the same event rather than a second open.
  final String? tokenId;

  /// Whether the cabinet believes something is in the compartment now. This is
  /// what moves a compartment to occupied; Milestone 1 is explicit that a
  /// booking alone does not.
  final bool itemInside;

  bool get isOpen => state == DoorState.open;
  bool get isFaulty => state == DoorState.faulty;

  /// True when this is the cabinet confirming an open that the system asked
  /// for, rather than reporting something it noticed.
  bool get confirmsCommand => isOpen && tokenId != null;

  @override
  String toString() =>
      'DoorEvent($stationId/$compartmentId, ${state.name}, '
      'trigger=${trigger?.name}, item=$itemInside)';
}
