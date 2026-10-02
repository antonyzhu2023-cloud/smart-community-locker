/// A booking of one compartment for one time window.
///
/// The state machine is from Milestone 1 (Figure 11). Two rules in it are not
/// obvious and are the reason this class exists rather than a plain map:
///
///  * A booking becomes [ReservationState.active] at the **first successful
///    open**, not at its start time, because users arrive late.
///  * A token may only be issued while the booking is confirmed or active.
///    Never when it is cancelled, expired or completed. This single rule is
///    what the server checks for FR4, and it lives here so there is one copy
///    of it rather than one per call site.
library;

enum ReservationState {
  /// Exists only for the moment the Firestore transaction is running.
  requested,

  /// The compartment is held. Tokens may be issued.
  confirmed,

  /// Opened at least once. Tokens may still be issued.
  active,

  /// The booked end time passed while an item was still inside.
  overdue,

  /// Item removed and door closed. Produces a usage record.
  completed,

  /// Cancelled by the user before it was used.
  cancelled,

  /// Start window passed and it was never opened.
  expired,
}

enum ReservationPurpose { parcel, handover, storage }

class Reservation {
  const Reservation({
    required this.id,
    required this.userId,
    required this.stationId,
    required this.compartmentId,
    required this.purpose,
    required this.startTime,
    required this.endTime,
    required this.state,
  });

  final String id;
  final String userId;
  final String stationId;
  final String compartmentId;
  final ReservationPurpose purpose;
  final DateTime startTime;
  final DateTime endTime;
  final ReservationState state;

  /// The rule the access token service enforces for FR4.
  bool get canIssueToken =>
      state == ReservationState.confirmed || state == ReservationState.active;

  /// Past its booked end time. Note this is about the clock, not the state:
  /// a booking can be expired by the clock before anything has moved it to
  /// [ReservationState.overdue].
  bool isExpired(DateTime now) => now.isAfter(endTime);

  /// A booking can only be extended while it is still live and has not been
  /// closed off. Extending an overdue booking is allowed, because that is the
  /// user clearing a fee rather than getting one for free.
  bool canExtend(DateTime now) {
    const extendable = {
      ReservationState.confirmed,
      ReservationState.active,
      ReservationState.overdue,
    };
    return extendable.contains(state);
  }

  /// True once the booking has reached a state it cannot leave.
  bool get isFinished =>
      state == ReservationState.completed ||
      state == ReservationState.cancelled ||
      state == ReservationState.expired;

  Duration remaining(DateTime now) {
    final left = endTime.difference(now);
    return left.isNegative ? Duration.zero : left;
  }

  Reservation copyWith({
    ReservationState? state,
    DateTime? startTime,
    DateTime? endTime,
  }) {
    return Reservation(
      id: id,
      userId: userId,
      stationId: stationId,
      compartmentId: compartmentId,
      purpose: purpose,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      state: state ?? this.state,
    );
  }

  @override
  String toString() => 'Reservation($id, ${state.name}, $startTime..$endTime)';
}
