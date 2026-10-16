import 'dart:async';

import '../../models/door_event.dart';

/// The cabinet, and only the cabinet.
///
/// This class actuates a door and reports what the door did. It makes no
/// decision about whether a door *should* open: it is told to open, and it
/// opens. That split is the whole point of Milestone 1's design, and it is the
/// reason this class exists separately from anything that validates a
/// credential.
///
/// Until now the split was described but not built. [InMemoryAccessBackend]
/// held the decision and the actuation in one object, which was fine while both
/// were simulated, but hid the fact that they are two different machines in two
/// different places. Once the decision moved to a real Cloud Function, the
/// cabinet had to become its own thing.
///
/// What a real cabinet would do instead: subscribe to an MQTT topic, drive a
/// solenoid, read a reed switch, and publish the result on a second topic. The
/// `simulator/locker_sim.py` script does exactly that. This class is the same
/// shape with the broker taken out, so the app can be demonstrated on one
/// machine.
///
/// ### Why opening and reporting are separate
///
/// [open] returns nothing. The door event arrives later, on [doorEvents], after
/// [reportDelay]. A method that returned "opened" would be claiming two facts
/// at once: that the command was accepted, and that a piece of metal moved.
/// Those are different facts and they can disagree. FR5 exists because they
/// can disagree.
class SimulatedCabinet {
  SimulatedCabinet({this.reportDelay, DateTime Function()? now})
    : _now = now ?? (() => DateTime.now().toUtc());

  /// How long the cabinet takes to report what the door did.
  ///
  /// Null means it reports in the same breath as being asked, which no real
  /// cabinet does. A delay is what makes the honest intermediate state (the
  /// command was accepted, the door has not said anything yet) observable at
  /// all.
  ///
  /// The demo build sets three seconds so the state can be read in a
  /// screenshot. A real round trip over MQTT plus a solenoid plus a reed switch
  /// is normally well under a second. Any figure showing this state has to say
  /// which it is.
  final Duration? reportDelay;

  final DateTime Function() _now;

  final Map<String, StreamController<DoorEvent>> _streams = {};

  /// Token ids this cabinet has already acted on.
  ///
  /// MQTT QoS 1 is at-least-once, so the same open command can arrive twice.
  /// Milestone 1 put the fix in the firmware: remember the token id and ignore
  /// a repeat. A second delivery must not count as a second open, because the
  /// audit trail would then show two opens for one credential.
  final Set<String> _actedOn = {};

  /// What the door sensor on one compartment reports.
  Stream<DoorEvent> doorEvents({
    required String stationId,
    required String compartmentId,
  }) => _streamFor(stationId, compartmentId).stream;

  /// Drives the lock open.
  ///
  /// Returns true when the command was acted on, and false when it was a
  /// repeat that the idempotency rule swallowed. The caller normally ignores
  /// the result; a test does not.
  bool open({
    required String stationId,
    required String compartmentId,
    String? tokenId,
    DoorTrigger trigger = DoorTrigger.token,
  }) {
    if (tokenId != null && _actedOn.contains(tokenId)) return false;
    if (tokenId != null) _actedOn.add(tokenId);

    _emit(
      DoorEvent(
        stationId: stationId,
        compartmentId: compartmentId,
        state: DoorState.open,
        at: _now(),
        trigger: trigger,
        tokenId: tokenId,
      ),
    );
    return true;
  }

  /// The door was shut. A compartment becomes occupied only when the door
  /// closes with something inside, which is a different event at a different
  /// time from the open.
  void reportClosed({
    required String stationId,
    required String compartmentId,
    required bool itemInside,
  }) {
    _emit(
      DoorEvent(
        stationId: stationId,
        compartmentId: compartmentId,
        state: DoorState.closed,
        at: _now(),
        trigger: DoorTrigger.userClosed,
        itemInside: itemInside,
      ),
    );
  }

  /// The door was told to open and did not. The compartment needs a human.
  void reportFaulty({
    required String stationId,
    required String compartmentId,
  }) {
    _emit(
      DoorEvent(
        stationId: stationId,
        compartmentId: compartmentId,
        state: DoorState.faulty,
        at: _now(),
      ),
    );
  }

  void _emit(DoorEvent event) {
    // ignore: close_sinks
    final controller = _streamFor(event.stationId, event.compartmentId);
    final delay = reportDelay;

    if (delay == null) {
      if (!controller.isClosed) controller.add(event);
      return;
    }

    // Fire and forget on purpose. What the door did arrives on its own
    // schedule, which is the reason it is reported separately rather than
    // returned from [open]. The isClosed check stops a delayed report arriving
    // after the cabinet has been torn down.
    unawaited(
      Future<void>.delayed(delay, () {
        if (!controller.isClosed) controller.add(event);
      }),
    );
  }

  StreamController<DoorEvent> _streamFor(
    String stationId,
    String compartmentId,
  ) {
    return _streams.putIfAbsent(
      '$stationId/$compartmentId',
      () => StreamController<DoorEvent>.broadcast(),
    );
  }

  Future<void> dispose() async {
    for (final controller in _streams.values) {
      await controller.close();
    }
    _streams.clear();
  }
}
