import '../models/reservation.dart';

/// Booking, cancelling and extending (FR3).
///
/// The important method is [book]. Milestone 1 specified that two users racing
/// for the same compartment must resolve to exactly one winner, with the loser
/// offered an alternative rather than shown an error. That is evaluation
/// criterion E3, and it is the reason the design chose Firestore: its
/// transactions give the hold-or-fail behaviour without a lock service.
///
/// This interface deliberately exposes no "check whether it is free" method.
/// Such a method would invite the caller to read, decide, then write, which is
/// precisely the race the design is meant to avoid. The only way to find out
/// whether a compartment is available is to try to book it.
abstract class BookingRepository {
  /// Holds [compartmentId] for [userId] from now until [end].
  ///
  /// Returns a confirmed [Reservation], or throws
  /// [BookingFailure.compartmentTaken] if someone else got there first. The
  /// check and the hold happen together; there is no window between them.
  Future<Reservation> book({
    required String userId,
    required String stationId,
    required String compartmentId,
    required ReservationPurpose purpose,
    required DateTime end,
  });

  /// Bookings belonging to one user, newest first.
  Future<List<Reservation>> fetchBookings(String userId);

  /// One booking by id.
  ///
  /// Needed by FR7: somebody holding a handed-over token has to be shown what
  /// they have been given, and that booking is not theirs. The server allows
  /// the read because they hold a token for it, which is the same reason it
  /// will let them open the door.
  Future<Reservation?> fetchBooking(String reservationId);

  Future<Reservation> cancel(String reservationId);

  /// Pushes the end time out. Refused once the booking is finished.
  Future<Reservation> extend(String reservationId, DateTime newEnd);
}

enum BookingFailure {
  /// Someone else holds it. The caller should offer the next free compartment.
  compartmentTaken,

  /// The compartment is out of service, or the station is offline.
  compartmentUnusable,

  /// No such compartment or station.
  notFound,

  /// The account is not a verified community member (E1).
  notEligible,

  /// The booking has been cancelled, completed or has expired.
  bookingFinished,

  /// The requested end time is in the past, or beyond the maximum stay.
  invalidWindow,

  network,
  unknown,
}

class BookingException implements Exception {
  const BookingException(this.failure, this.message, {this.alternative});

  final BookingFailure failure;

  /// Shown to the user as written.
  final String message;

  /// The next free compartment of the same size, when there is one. Set on
  /// [BookingFailure.compartmentTaken] so the ViewModel can offer it straight
  /// away instead of sending the user back to the list, which is the recovery
  /// behaviour Milestone 1 specified for a lost race.
  final String? alternative;

  bool get hasAlternative => alternative != null;

  @override
  String toString() => 'BookingException(${failure.name}): $message';
}
