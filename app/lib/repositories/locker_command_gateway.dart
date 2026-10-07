import '../models/door_event.dart';

/// The boundary between the app and the physical cabinet (FR5).
///
/// Milestone 1 called this the Gateway, and named it as the one seam that makes
/// Milestone 2 possible at all: behind it sits either an MQTT broker talking to
/// an ESP32, a Python script pretending to be one, or a fake in a test, and
/// nothing above this interface can tell the difference. Without it, every test
/// of the opening path would need a broker and a cabinet.
///
/// ### What this interface deliberately cannot do
///
/// There is no `open(compartmentId)`. The app never opens a locker; it presents
/// a credential and the server decides. Milestone 1 was explicit that the
/// cabinet does not validate codes either — it publishes what it scanned and
/// waits to be told. Keeping the decision in one place is what makes evaluation
/// criterion E4 testable: there is exactly one piece of code that can say yes.
abstract class LockerCommandGateway {
  /// Presents a credential, as the cabinet's scanner would.
  ///
  /// Used by the remote-open path, which Milestone 1 chose to build first
  /// because it needs no camera and runs entirely on the emulator. The real
  /// cabinet reaches the same server code by publishing to MQTT instead.
  ///
  /// Either [payload] or [pin] must be given. [pin] is the offline backup from
  /// QR4 and is checked by the cabinet against a cached hash, so it still works
  /// when the network is down.
  Future<OpenOutcome> present({
    required String stationId,
    required String compartmentId,
    String? payload,
    String? pin,
  });

  /// Door events for one compartment, as reported by its sensor.
  ///
  /// This is a stream rather than a return value from [present] because the two
  /// are genuinely separate: the command is acknowledged by the broker, and the
  /// door reports what actually happened some time later, or never.
  Stream<DoorEvent> doorEvents({
    required String stationId,
    required String compartmentId,
  });

  /// Whether the gateway currently has a link to the broker. Drives the offline
  /// banner and decides whether the PIN path is offered.
  bool get isConnected;

  Stream<bool> connectionChanges();

  Future<void> dispose();
}

/// What the server decided, as far as the app is concerned.
enum OpenDecision {
  /// Accepted. A door event should follow, but may not.
  accepted,

  /// The token has passed its 120 second life.
  expired,

  /// Single use, and it has been used.
  alreadyUsed,

  /// The signature did not verify, or the payload was altered.
  invalidSignature,

  /// The booking is cancelled, completed or expired, so no token for it may be
  /// honoured. The rule from Milestone 1 that the server checks for FR4.
  bookingNotOpenable,

  /// The credential belongs to a different account.
  notYours,

  /// Wrong backup PIN.
  wrongPin,

  /// The cabinet is unreachable and no PIN was offered.
  cabinetUnreachable,

  unknown,
}

class OpenOutcome {
  const OpenOutcome({
    required this.decision,
    required this.message,
    this.tokenId,
    this.at,
  });

  final OpenDecision decision;

  /// Shown to the user as written. Free of internal detail, per QR5.
  final String message;

  final String? tokenId;
  final DateTime? at;

  bool get accepted => decision == OpenDecision.accepted;

  /// Every refusal is logged server-side, which is the second half of E4. The
  /// app does not decide what gets logged; it only reports what it was told.
  bool get refused => !accepted;

  @override
  String toString() => 'OpenOutcome(${decision.name}, token=$tokenId)';
}

class GatewayException implements Exception {
  const GatewayException(this.message);
  final String message;

  @override
  String toString() => 'GatewayException: $message';
}
