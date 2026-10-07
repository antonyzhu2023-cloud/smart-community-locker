import 'package:flutter/foundation.dart';

import '../models/access_token.dart';
import '../models/reservation.dart';
import '../repositories/access_token_repository.dart';
import '../repositories/booking_repository.dart';

/// The user's own bookings, with cancel and extend (FR3).
///
/// Split from `BookingViewModel` because the two screens have nothing in
/// common except the repository: one is a form that ends in a single write, the
/// other is a list that changes items in place. Putting both in one class would
/// have produced a ViewModel with two unrelated halves and twice as many states
/// to reason about in tests.
class MyBookingsViewModel extends ChangeNotifier {
  MyBookingsViewModel(this._repository, this._userId, {this.tokens});

  final BookingRepository _repository;
  final String _userId;

  /// Optional. When given, the list also shows bookings somebody else has
  /// handed to this user (FR7). Optional because most tests of this class have
  /// nothing to do with hand-overs and should not have to build an access
  /// backend to run.
  final AccessTokenRepository? tokens;

  List<Reservation> _bookings = const [];
  List<SharedBooking> _shared = const [];
  bool _loading = false;
  String? _error;

  /// Ids of bookings with a cancel or extend in flight. Held per booking so one
  /// row can show a spinner without disabling the whole list.
  final Set<String> _working = {};

  List<Reservation> get bookings => _bookings;
  bool get isLoading => _loading;
  String? get error => _error;
  bool get hasError => _error != null;

  /// Bookings handed to this user by a neighbour.
  List<SharedBooking> get sharedWithMe => _shared;
  bool get hasShared => _shared.isNotEmpty;

  bool get isEmpty =>
      !_loading && _error == null && _bookings.isEmpty && _shared.isEmpty;

  bool isWorkingOn(String reservationId) => _working.contains(reservationId);

  /// Bookings that are still live, newest first. What the user normally wants.
  List<Reservation> get active =>
      _bookings.where((r) => !r.isFinished).toList(growable: false);

  List<Reservation> get past =>
      _bookings.where((r) => r.isFinished).toList(growable: false);

  Future<void> load() async {
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      _bookings = await _repository.fetchBookings(_userId);
      _shared = await _loadShared();
    } on BookingException catch (e) {
      _error = e.message;
      _bookings = const [];
      _shared = const [];
    } catch (_) {
      _error = 'Could not load your bookings. Check your connection.';
      _bookings = const [];
      _shared = const [];
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Bookings somebody else has given this user a code for (FR7).
  ///
  /// Each one is looked up by id because it is not theirs. The server allows
  /// the read for the same reason it will let them open the door: they hold a
  /// token for it.
  Future<List<SharedBooking>> _loadShared() async {
    final repository = tokens;
    if (repository == null) return const [];

    final delegations = await repository.delegationsTo(_userId);
    final shared = <SharedBooking>[];

    for (final token in delegations) {
      final booking = await _repository.fetchBooking(token.reservationId);
      // A booking that has gone, or that the owner has since cancelled, is
      // dropped rather than shown as something the neighbour can open.
      if (booking == null || booking.isFinished) continue;
      shared.add(SharedBooking(booking: booking, token: token));
    }
    return List.unmodifiable(shared);
  }

  /// Replaces one booking in the list without reloading the rest.
  void _replace(Reservation updated) {
    _bookings = [
      for (final booking in _bookings)
        if (booking.id == updated.id) updated else booking,
    ];
  }

  Future<bool> _change(
    String reservationId,
    Future<Reservation> Function() action,
  ) async {
    if (_working.contains(reservationId)) return false;
    _working.add(reservationId);
    _error = null;
    notifyListeners();

    try {
      _replace(await action());
      return true;
    } on BookingException catch (e) {
      _error = e.message;
      return false;
    } catch (_) {
      _error = 'That did not go through. Check your connection and try again.';
      return false;
    } finally {
      _working.remove(reservationId);
      notifyListeners();
    }
  }

  Future<bool> cancel(String reservationId) =>
      _change(reservationId, () => _repository.cancel(reservationId));

  /// Adds [by] to the booking's current end time.
  Future<bool> extend(String reservationId, Duration by) {
    Reservation? booking;
    for (final candidate in _bookings) {
      if (candidate.id == reservationId) booking = candidate;
    }
    if (booking == null) {
      _error = 'That booking is no longer in your list.';
      notifyListeners();
      return Future.value(false);
    }

    final newEnd = booking.endTime.add(by);
    return _change(
      reservationId,
      () => _repository.extend(reservationId, newEnd),
    );
  }

  void clearError() {
    if (_error == null) return;
    _error = null;
    notifyListeners();
  }
}

/// A booking a neighbour has given this user a code for, with that code.
///
/// The two travel together because neither is any use on its own. The booking
/// says which locker and until when. The token is the only reason this user is
/// allowed to see it.
class SharedBooking {
  const SharedBooking({required this.booking, required this.token});

  final Reservation booking;
  final AccessToken token;

  @override
  String toString() => 'SharedBooking(${booking.compartmentId}, ${token.id})';
}
