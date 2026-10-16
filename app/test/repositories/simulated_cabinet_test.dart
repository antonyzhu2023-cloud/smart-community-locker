import 'package:flutter_test/flutter_test.dart';
import 'package:scls/models/door_event.dart';
import 'package:scls/repositories/firebase/simulated_cabinet.dart';

/// Tests for the cabinet on its own.
///
/// The cabinet used to be half of [InMemoryAccessBackend], where it could only
/// be tested through a credential check it has nothing to do with. Splitting it
/// out made these cases possible to write, and two of them cover behaviour that
/// had no test at all before: that a repeated command is swallowed, and that
/// opening reports nothing until the door says something.
void main() {
  final fixed = DateTime.utc(2026, 10, 16, 9);
  DateTime clock() => fixed;

  group('reporting what the door did', () {
    test('an open is reported on the stream for that compartment', () async {
      final cabinet = SimulatedCabinet(now: clock);
      addTearDown(cabinet.dispose);

      final events = cabinet.doorEvents(
        stationId: 'ST-1',
        compartmentId: 'C-1',
      );
      final seen = <DoorEvent>[];
      final subscription = events.listen(seen.add);

      cabinet.open(stationId: 'ST-1', compartmentId: 'C-1', tokenId: 'tok-1');
      await Future<void>.delayed(Duration.zero);

      expect(seen, hasLength(1));
      expect(seen.single.state, DoorState.open);
      expect(seen.single.tokenId, 'tok-1');
      expect(seen.single.trigger, DoorTrigger.token);
      await subscription.cancel();
    });

    test('an open is not reported on another compartment', () async {
      final cabinet = SimulatedCabinet(now: clock);
      addTearDown(cabinet.dispose);

      final seen = <DoorEvent>[];
      final subscription = cabinet
          .doorEvents(stationId: 'ST-1', compartmentId: 'C-2')
          .listen(seen.add);

      cabinet.open(stationId: 'ST-1', compartmentId: 'C-1', tokenId: 'tok-1');
      await Future<void>.delayed(Duration.zero);

      expect(seen, isEmpty);
      await subscription.cancel();
    });

    test('nothing is reported until the delay has passed', () async {
      final cabinet = SimulatedCabinet(
        reportDelay: const Duration(milliseconds: 40),
        now: clock,
      );
      addTearDown(cabinet.dispose);

      final seen = <DoorEvent>[];
      final subscription = cabinet
          .doorEvents(stationId: 'ST-1', compartmentId: 'C-1')
          .listen(seen.add);

      cabinet.open(stationId: 'ST-1', compartmentId: 'C-1', tokenId: 'tok-1');

      // The command has been accepted and the door has said nothing. This is
      // the state FR5 exists for, and it has a duration.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(seen, isEmpty);

      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(seen, hasLength(1));
      await subscription.cancel();
    });

    test('a delayed report after dispose does not throw', () async {
      final cabinet = SimulatedCabinet(
        reportDelay: const Duration(milliseconds: 30),
        now: clock,
      );

      cabinet
          .doorEvents(stationId: 'ST-1', compartmentId: 'C-1')
          .listen((_) {});
      cabinet.open(stationId: 'ST-1', compartmentId: 'C-1', tokenId: 'tok-1');

      await cabinet.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      // Reaching here without an error is the assertion.
    });
  });

  group('idempotency', () {
    test('the same token twice opens once', () async {
      final cabinet = SimulatedCabinet(now: clock);
      addTearDown(cabinet.dispose);

      final seen = <DoorEvent>[];
      final subscription = cabinet
          .doorEvents(stationId: 'ST-1', compartmentId: 'C-1')
          .listen(seen.add);

      final first = cabinet.open(
        stationId: 'ST-1',
        compartmentId: 'C-1',
        tokenId: 'tok-1',
      );
      final second = cabinet.open(
        stationId: 'ST-1',
        compartmentId: 'C-1',
        tokenId: 'tok-1',
      );
      await Future<void>.delayed(Duration.zero);

      expect(first, isTrue);
      expect(
        second,
        isFalse,
        reason:
            'MQTT QoS 1 can deliver the same '
            'command twice, and a second delivery is not a second open',
      );
      expect(seen, hasLength(1));
      await subscription.cancel();
    });

    test('two different tokens open twice', () async {
      final cabinet = SimulatedCabinet(now: clock);
      addTearDown(cabinet.dispose);

      final seen = <DoorEvent>[];
      final subscription = cabinet
          .doorEvents(stationId: 'ST-1', compartmentId: 'C-1')
          .listen(seen.add);

      cabinet.open(stationId: 'ST-1', compartmentId: 'C-1', tokenId: 'tok-1');
      cabinet.open(stationId: 'ST-1', compartmentId: 'C-1', tokenId: 'tok-2');
      await Future<void>.delayed(Duration.zero);

      expect(seen, hasLength(2));
      await subscription.cancel();
    });

    test('an open with no token is never swallowed', () async {
      final cabinet = SimulatedCabinet(now: clock);
      addTearDown(cabinet.dispose);

      final seen = <DoorEvent>[];
      final subscription = cabinet
          .doorEvents(stationId: 'ST-1', compartmentId: 'C-1')
          .listen(seen.add);

      // A building manager opening a compartment by hand has no token, and
      // doing it twice is two opens, not one.
      cabinet.open(
        stationId: 'ST-1',
        compartmentId: 'C-1',
        trigger: DoorTrigger.manual,
      );
      cabinet.open(
        stationId: 'ST-1',
        compartmentId: 'C-1',
        trigger: DoorTrigger.manual,
      );
      await Future<void>.delayed(Duration.zero);

      expect(seen, hasLength(2));
      await subscription.cancel();
    });
  });

  group('closing and faults', () {
    test('a close carries whether something is inside', () async {
      final cabinet = SimulatedCabinet(now: clock);
      addTearDown(cabinet.dispose);

      final seen = <DoorEvent>[];
      final subscription = cabinet
          .doorEvents(stationId: 'ST-1', compartmentId: 'C-1')
          .listen(seen.add);

      cabinet.reportClosed(
        stationId: 'ST-1',
        compartmentId: 'C-1',
        itemInside: true,
      );
      await Future<void>.delayed(Duration.zero);

      expect(seen.single.state, DoorState.closed);
      expect(seen.single.itemInside, isTrue);
      expect(seen.single.trigger, DoorTrigger.userClosed);
      await subscription.cancel();
    });

    test('a fault is reported with no trigger', () async {
      final cabinet = SimulatedCabinet(now: clock);
      addTearDown(cabinet.dispose);

      final seen = <DoorEvent>[];
      final subscription = cabinet
          .doorEvents(stationId: 'ST-1', compartmentId: 'C-1')
          .listen(seen.add);

      cabinet.reportFaulty(stationId: 'ST-1', compartmentId: 'C-1');
      await Future<void>.delayed(Duration.zero);

      expect(seen.single.isFaulty, isTrue);
      expect(seen.single.trigger, isNull);
      await subscription.cancel();
    });

    test('a told-to-open door that reports faulty is not an open', () async {
      final cabinet = SimulatedCabinet(now: clock);
      addTearDown(cabinet.dispose);

      final seen = <DoorEvent>[];
      final subscription = cabinet
          .doorEvents(stationId: 'ST-1', compartmentId: 'C-1')
          .listen(seen.add);

      // The command was accepted and the solenoid jammed. A system that
      // treats the command as the outcome tells the user their parcel is
      // reachable while it is locked in.
      cabinet.reportFaulty(stationId: 'ST-1', compartmentId: 'C-1');
      await Future<void>.delayed(Duration.zero);

      expect(seen.single.isOpen, isFalse);
      expect(seen.single.confirmsCommand, isFalse);
      await subscription.cancel();
    });
  });

  test('the clock is the injected one', () async {
    final cabinet = SimulatedCabinet(now: clock);
    addTearDown(cabinet.dispose);

    final seen = <DoorEvent>[];
    final subscription = cabinet
        .doorEvents(stationId: 'ST-1', compartmentId: 'C-1')
        .listen(seen.add);

    cabinet.open(stationId: 'ST-1', compartmentId: 'C-1', tokenId: 'tok-1');
    await Future<void>.delayed(Duration.zero);

    expect(seen.single.at, fixed);
    await subscription.cancel();
  });
}
