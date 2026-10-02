import 'package:flutter_test/flutter_test.dart';
import 'package:scls/models/reservation.dart';

/// These tests pin the two booking rules from Milestone 1 that are easy to get
/// wrong and expensive to get wrong: when a token may be issued, and what
/// "expired" means.
void main() {
  final now = DateTime(2026, 10, 2, 12, 0);

  Reservation build({
    required ReservationState state,
    DateTime? start,
    DateTime? end,
  }) {
    return Reservation(
      id: 'R1',
      userId: 'U1',
      stationId: 'STATION-01',
      compartmentId: 'S1-A1',
      purpose: ReservationPurpose.parcel,
      startTime: start ?? now.subtract(const Duration(hours: 1)),
      endTime: end ?? now.add(const Duration(hours: 1)),
      state: state,
    );
  }

  group('canIssueToken', () {
    test('allows confirmed and active', () {
      expect(build(state: ReservationState.confirmed).canIssueToken, isTrue);
      expect(build(state: ReservationState.active).canIssueToken, isTrue);
    });

    test('refuses every other state', () {
      const refused = [
        ReservationState.requested,
        ReservationState.overdue,
        ReservationState.completed,
        ReservationState.cancelled,
        ReservationState.expired,
      ];
      for (final state in refused) {
        expect(
          build(state: state).canIssueToken,
          isFalse,
          reason: 'a token must not be issued while $state',
        );
      }
    });

    test('covers every state in the enum', () {
      // Guards against someone adding a state later and forgetting the rule.
      var allowed = 0;
      for (final state in ReservationState.values) {
        if (build(state: state).canIssueToken) allowed++;
      }
      expect(allowed, 2, reason: 'only confirmed and active may issue tokens');
    });
  });

  group('isExpired', () {
    test('is false before the end time', () {
      final r = build(
        state: ReservationState.active,
        end: now.add(const Duration(minutes: 1)),
      );
      expect(r.isExpired(now), isFalse);
    });

    test('is false exactly at the end time', () {
      final r = build(state: ReservationState.active, end: now);
      expect(r.isExpired(now), isFalse);
    });

    test('is true after the end time', () {
      final r = build(
        state: ReservationState.active,
        end: now.subtract(const Duration(seconds: 1)),
      );
      expect(r.isExpired(now), isTrue);
    });
  });

  group('canExtend', () {
    test('allows confirmed, active and overdue', () {
      expect(build(state: ReservationState.confirmed).canExtend(now), isTrue);
      expect(build(state: ReservationState.active).canExtend(now), isTrue);
      // Overdue is deliberately extendable: that is a user clearing a fee.
      expect(build(state: ReservationState.overdue).canExtend(now), isTrue);
    });

    test('refuses finished bookings', () {
      expect(build(state: ReservationState.completed).canExtend(now), isFalse);
      expect(build(state: ReservationState.cancelled).canExtend(now), isFalse);
      expect(build(state: ReservationState.expired).canExtend(now), isFalse);
    });
  });

  group('isFinished', () {
    test('is true only for terminal states', () {
      expect(build(state: ReservationState.completed).isFinished, isTrue);
      expect(build(state: ReservationState.cancelled).isFinished, isTrue);
      expect(build(state: ReservationState.expired).isFinished, isTrue);
      expect(build(state: ReservationState.active).isFinished, isFalse);
      expect(build(state: ReservationState.overdue).isFinished, isFalse);
    });
  });

  group('remaining', () {
    test('counts down while the booking is live', () {
      final r = build(
        state: ReservationState.active,
        end: now.add(const Duration(minutes: 30)),
      );
      expect(r.remaining(now), const Duration(minutes: 30));
    });

    test('clamps to zero rather than going negative', () {
      final r = build(
        state: ReservationState.overdue,
        end: now.subtract(const Duration(hours: 2)),
      );
      expect(r.remaining(now), Duration.zero);
    });
  });

  test('copyWith changes only what it is given', () {
    final original = build(state: ReservationState.confirmed);
    final updated = original.copyWith(state: ReservationState.active);

    expect(updated.state, ReservationState.active);
    expect(updated.id, original.id);
    expect(updated.compartmentId, original.compartmentId);
    expect(updated.endTime, original.endTime);
  });
}
