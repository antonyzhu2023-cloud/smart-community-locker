import 'package:flutter/foundation.dart';

import '../models/compartment.dart';
import '../models/locker_station.dart';
import '../repositories/locker_repository.dart';

/// Screen state for the station list.
///
/// Milestone 1 planned a GPS map here (FR2). That was cut to a list once the
/// submission date was known: a map needs the Maps SDK, an API key and runtime
/// permissions, which is the largest amount of unfamiliar work for the smallest
/// marking return. The requirement "show nearby stations with their free
/// compartments" is still met.
///
/// This class is a plain [ChangeNotifier]. It holds no reference to any widget
/// and takes its repository through the constructor, so a unit test can build
/// it directly with a fake repository. That is what makes the coverage target
/// in QR6 reachable.
class StationListViewModel extends ChangeNotifier {
  StationListViewModel(this._repository);

  final LockerRepository _repository;

  List<LockerStation> _stations = const [];
  bool _loading = false;
  String? _error;
  SizeClass? _sizeFilter;

  bool get isLoading => _loading;
  String? get error => _error;
  SizeClass? get sizeFilter => _sizeFilter;
  bool get hasError => _error != null;

  /// Stations after the size filter is applied. A station is kept when it has
  /// at least one free compartment of the requested size.
  List<LockerStation> get stations {
    if (_sizeFilter == null) return _stations;
    return _stations
        .where((s) => s.availableOfSize(_sizeFilter!).isNotEmpty)
        .toList(growable: false);
  }

  /// True once a load has finished and there is genuinely nothing to show.
  /// Used to tell "still loading" apart from "no results", which are different
  /// messages to the user.
  bool get isEmpty => !_loading && _error == null && stations.isEmpty;

  int get totalFreeCompartments =>
      stations.fold(0, (sum, s) => sum + s.freeCount);

  Future<void> load() async {
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      _stations = await _repository.fetchStations();
    } on LockerRepositoryException catch (e) {
      _error = e.message;
      _stations = const [];
    } catch (_) {
      _error = 'Could not load stations. Check your connection and try again.';
      _stations = const [];
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Passing null clears the filter.
  void setSizeFilter(SizeClass? size) {
    if (_sizeFilter == size) return;
    _sizeFilter = size;
    notifyListeners();
  }
}
