import '../models/compartment.dart';
import '../models/reservation.dart';
import 'booking_repository.dart';
import 'in_memory_locker_repository.dart';

/// A [BookingRepository] over the in-memory stations.
///
/// It takes the locker repository rather than holding its own copy of the
/// compartments, because a booking has to change a compartment's state and the
/// station list has to see that change. In the Firebase build the two live in
/// different Firestore collections and the same write spans both inside one
/// transaction.
///
/// ### Why [book] has no `await` in the middle
///
/// Everything between reading the compartment's state and writing the hold is
/// synchronous. Dart runs one isolate, so a stretch of code with no `await` in
/// it cannot be interrupted, which makes the check-and-hold atomic. Any `await`
/// placed between the two would let a second caller read `free` before the
/// first wrote `reserved`, and both would think they had won. That is exactly
/// the defect evaluation criterion E3 tests for, and it is the reason the
/// simulated latency happens before the critical section rather than inside it.
class InMemoryBookingRepository implements BookingRepository {
  InMemoryBookingRepository(this._lockers, {this.delay, this.isEligible});

  final InMemoryLockerRepository _lockers;

  /// Lets a test or a demo simulate a slow network.
  final Duration? delay;

  /// Whether an account may book at all (E1). Null means no check, which is
  /// what the plain unit tests use. The app passes the auth repository's answer
  /// so that the rule is enforced below the UI as well as by the screen the
  /// user can reach.
  final bool Function(String userId)? isEligible;

  final Map<String, Reservation> _bookings = {};
  var _nextId = 1;

  /// The longest a compartment may be held. Beyond this the cabinet silts up
  /// with long-term storage, which is what the overdue fee is meant to stop.
  static const Duration maxStay = Duration(hours: 72);

  Future<void> _wait() async {
    if (delay != null) await Future<void>.delayed(delay!);
  }

  @override
  Future<Reservation> book({
    required String userId,
    required String stationId,
    required String compartmentId,
    required ReservationPurpose purpose,
    required DateTime end,
  }) async {
    // Simulated latency goes here, before the critical section, never inside.
    await _wait();

    final now = DateTime.now();

    if (isEligible != null && !isEligible!(userId)) {
      throw const BookingException(
        BookingFailure.notEligible,
        'Your account has to be verified before you can book.',
      );
    }
    if (!end.isAfter(now)) {
      throw const BookingException(
        BookingFailure.invalidWindow,
        'Choose an end time in the future.',
      );
    }
    if (end.difference(now) > maxStay) {
      throw const BookingException(
        BookingFailure.invalidWindow,
        'A locker can be held for up to 72 hours.',
      );
    }

    // ---- critical section: no await from here to the write ----
    final station = _lockers.stationById(stationId);
    if (station == null) {
      throw const BookingException(
        BookingFailure.notFound,
        'That locker station no longer exists.',
      );
    }

    final compartment = _lockers.compartmentById(stationId, compartmentId);
    if (compartment == null) {
      throw const BookingException(
        BookingFailure.notFound,
        'That compartment no longer exists.',
      );
    }

    if (compartment.state == CompartmentState.outOfService ||
        !station.isBookable) {
      throw const BookingException(
        BookingFailure.compartmentUnusable,
        'That locker is out of service right now.',
      );
    }

    if (!compartment.isAvailable) {
      // Lost the race. Look for something else at the same station so the user
      // can carry on rather than starting over.
      final alternative = _lockers.nextFreeOfSameSize(
        stationId,
        compartment.size,
        exceptId: compartmentId,
      );
      throw BookingException(
        BookingFailure.compartmentTaken,
        'Someone just took that locker.',
        alternative: alternative?.id,
      );
    }

    _lockers.setCompartmentState(
      stationId,
      compartmentId,
      CompartmentState.reserved,
    );
    // ---- end of critical section ----

    final reservation = Reservation(
      id: 'R${_nextId++}',
      userId: userId,
      stationId: stationId,
      compartmentId: compartmentId,
      purpose: purpose,
      startTime: now,
      endTime: end,
      state: ReservationState.confirmed,
    );
    _bookings[reservation.id] = reservation;
    return reservation;
  }

  @override
  Future<List<Reservation>> fetchBookings(String userId) async {
    await _wait();
    final mine = _bookings.values.where((r) => r.userId == userId).toList()
      ..sort((a, b) => b.startTime.compareTo(a.startTime));
    return List.unmodifiable(mine);
  }

  @override
  Future<Reservation> cancel(String reservationId) async {
    await _wait();

    final booking = _bookings[reservationId];
    if (booking == null) {
      throw const BookingException(
        BookingFailure.notFound,
        'That booking no longer exists.',
      );
    }
    if (booking.isFinished) {
      throw const BookingException(
        BookingFailure.bookingFinished,
        'That booking has already been closed.',
      );
    }

    final cancelled = booking.copyWith(state: ReservationState.cancelled);
    _bookings[reservationId] = cancelled;

    // Release the compartment. A booking that was already opened leaves an item
    // inside, so only an unopened hold frees the door.
    if (booking.state == ReservationState.confirmed) {
      _lockers.setCompartmentState(
        booking.stationId,
        booking.compartmentId,
        CompartmentState.free,
      );
    }
    return cancelled;
  }

  @override
  Future<Reservation> extend(String reservationId, DateTime newEnd) async {
    await _wait();

    final booking = _bookings[reservationId];
    if (booking == null) {
      throw const BookingException(
        BookingFailure.notFound,
        'That booking no longer exists.',
      );
    }

    final now = DateTime.now();
    if (!booking.canExtend(now)) {
      throw const BookingException(
        BookingFailure.bookingFinished,
        'That booking can no longer be extended.',
      );
    }
    if (!newEnd.isAfter(booking.endTime)) {
      throw const BookingException(
        BookingFailure.invalidWindow,
        'Choose a later end time than the one you have.',
      );
    }
    if (newEnd.difference(booking.startTime) > maxStay) {
      throw const BookingException(
        BookingFailure.invalidWindow,
        'A locker can be held for up to 72 hours in total.',
      );
    }

    final extended = booking.copyWith(endTime: newEnd);
    _bookings[reservationId] = extended;
    return extended;
  }
}
