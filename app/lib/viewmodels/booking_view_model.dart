import 'package:flutter/foundation.dart';

import '../models/compartment.dart';
import '../models/locker_station.dart';
import '../models/reservation.dart';
import '../repositories/booking_repository.dart';
import '../repositories/locker_repository.dart';

/// Screen state for booking one compartment at one station (FR3).
///
/// The interesting part is [lostRace]. Milestone 1 said that when two users go
/// for the same compartment, the one who loses is offered the next free
/// compartment rather than being shown an error and sent back to the list.
/// That recovery lives here: the repository reports the conflict and names an
/// alternative, and this class turns it into a state the screen can offer in
/// one tap.
class BookingViewModel extends ChangeNotifier {
  BookingViewModel(this._bookings, this._lockers);

  final BookingRepository _bookings;
  final LockerRepository _lockers;

  /// The stay lengths the screen offers. Three options rather than a date and
  /// time picker: QR2 caps booking at four screens, and a picker is a screen.
  static const List<Duration> stayOptions = [
    Duration(hours: 2),
    Duration(hours: 24),
    Duration(hours: 72),
  ];

  LockerStation? _station;
  Compartment? _selected;
  Duration _stay = stayOptions.first;
  ReservationPurpose _purpose = ReservationPurpose.parcel;

  bool _loading = false;
  bool _submitting = false;
  String? _error;
  String? _lostRaceAlternative;
  Reservation? _confirmed;

  LockerStation? get station => _station;
  Compartment? get selected => _selected;
  Duration get stay => _stay;
  ReservationPurpose get purpose => _purpose;

  bool get isLoading => _loading;
  bool get isSubmitting => _submitting;
  String? get error => _error;
  bool get hasError => _error != null;

  /// The booking that was just confirmed. The screen shows a receipt and stops
  /// accepting input once this is set.
  Reservation? get confirmed => _confirmed;
  bool get isConfirmed => _confirmed != null;

  /// Set when the chosen compartment was taken and another one is free. The
  /// screen offers it; [acceptAlternative] takes it.
  String? get lostRaceAlternative => _lostRaceAlternative;
  bool get lostRace => _lostRaceAlternative != null;

  List<Compartment> get availableCompartments =>
      _station?.availableCompartments ?? const [];

  /// True when the station has nothing left to book. Separate from an error:
  /// the screen says so plainly instead of showing a failure.
  bool get isFull =>
      !_loading && _station != null && availableCompartments.isEmpty;

  bool get canSubmit =>
      _selected != null && !_submitting && !isConfirmed && !_loading;

  Compartment? _availableById(String id) {
    for (final compartment in availableCompartments) {
      if (compartment.id == id) return compartment;
    }
    return null;
  }

  Future<void> openStation(String stationId) async {
    _loading = true;
    _error = null;
    _confirmed = null;
    _lostRaceAlternative = null;
    notifyListeners();

    try {
      _station = await _lockers.fetchStation(stationId);
      if (_station == null) {
        _error = 'That locker station is no longer listed.';
      }
      // Keep a selection only if it is still free after the refresh.
      final still = _selected;
      if (still != null) _selected = _availableById(still.id);
    } on LockerRepositoryException catch (e) {
      _error = e.message;
      _station = null;
    } catch (_) {
      _error = 'Could not load that station. Check your connection.';
      _station = null;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  void selectCompartment(Compartment? compartment) {
    if (_selected?.id == compartment?.id) return;
    _selected = compartment;
    _error = null;
    _lostRaceAlternative = null;
    notifyListeners();
  }

  void setStay(Duration stay) {
    if (_stay == stay) return;
    _stay = stay;
    notifyListeners();
  }

  void setPurpose(ReservationPurpose purpose) {
    if (_purpose == purpose) return;
    _purpose = purpose;
    notifyListeners();
  }

  /// Takes the compartment offered after a lost race, and books it.
  Future<bool> acceptAlternative(String userId) async {
    final id = _lostRaceAlternative;
    final station = _station;
    if (id == null || station == null) return false;

    // Re-read the station so the alternative is a live object, not one from
    // before the conflict.
    await openStation(station.id);
    final replacement = _availableById(id);

    if (replacement == null) {
      _error = 'That one has gone as well. Pick another locker.';
      _lostRaceAlternative = null;
      notifyListeners();
      return false;
    }

    _selected = replacement;
    notifyListeners();
    return submit(userId);
  }

  Future<bool> submit(String userId) async {
    final compartment = _selected;
    final station = _station;
    if (compartment == null || station == null) {
      _error = 'Choose a locker first.';
      notifyListeners();
      return false;
    }

    _submitting = true;
    _error = null;
    _lostRaceAlternative = null;
    notifyListeners();

    try {
      _confirmed = await _bookings.book(
        userId: userId,
        stationId: station.id,
        compartmentId: compartment.id,
        purpose: _purpose,
        end: DateTime.now().add(_stay),
      );
      return true;
    } on BookingException catch (e) {
      _error = e.message;
      _lostRaceAlternative = e.alternative;
      return false;
    } catch (_) {
      _error = 'Could not complete the booking. Check your connection.';
      return false;
    } finally {
      _submitting = false;
      notifyListeners();
    }
  }

  /// Clears the confirmation so the screen can be used again.
  void reset() {
    _selected = null;
    _confirmed = null;
    _error = null;
    _lostRaceAlternative = null;
    notifyListeners();
  }
}
