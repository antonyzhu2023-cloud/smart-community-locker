import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'repositories/auth_repository.dart';
import 'repositories/booking_repository.dart';
import 'repositories/in_memory_auth_repository.dart';
import 'repositories/in_memory_booking_repository.dart';
import 'repositories/in_memory_locker_repository.dart';
import 'repositories/locker_repository.dart';
import 'viewmodels/auth_view_model.dart';
import 'viewmodels/station_list_view_model.dart';
import 'views/root_view.dart';

void main() {
  runApp(const SclsApp());
}

/// Smart Community Locker System.
///
/// Dependencies are built here and injected, rather than reached for inside the
/// classes that use them. Milestone 1 ruled out the Singleton pattern for
/// exactly this reason: a static `getInstance()` cannot be replaced in a test,
/// which would put the 70% coverage target in QR6 out of reach.
///
/// All three repositories are still the in-memory implementations. Swapping
/// them for the Firebase ones is a change to this file and nothing else, which
/// is the claim Milestone 1 made for the repository layer.
///
/// A [StatefulWidget] rather than a [StatelessWidget] because the repositories
/// hold state. Building them in `build` would quietly throw away every account
/// and booking whenever the framework rebuilt this widget.
class SclsApp extends StatefulWidget {
  const SclsApp({super.key});

  @override
  State<SclsApp> createState() => _SclsAppState();
}

class _SclsAppState extends State<SclsApp> {
  late final InMemoryLockerRepository _lockers;
  late final InMemoryAuthRepository _auth;
  late final InMemoryBookingRepository _bookings;

  @override
  void initState() {
    super.initState();
    _lockers = InMemoryLockerRepository();
    _auth = InMemoryAuthRepository();
    _bookings = InMemoryBookingRepository(
      _lockers,
      // E1 again, one layer below the screens. The booking screen is already
      // unreachable for an unverified account, but a rule that lives only in
      // the UI is a rule that a later change to the UI can remove by accident.
      isEligible: (userId) {
        final user = _auth.currentUser;
        return user != null && user.id == userId && user.isEligible;
      },
    );
  }

  @override
  void dispose() {
    _auth.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<LockerRepository>.value(value: _lockers),
        Provider<AuthRepository>.value(value: _auth),
        Provider<BookingRepository>.value(value: _bookings),
        ChangeNotifierProvider<AuthViewModel>(
          create: (context) => AuthViewModel(context.read<AuthRepository>()),
        ),
        ChangeNotifierProvider<StationListViewModel>(
          create: (context) =>
              StationListViewModel(context.read<LockerRepository>()),
        ),
      ],
      child: MaterialApp(
        title: 'Smart Community Locker',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1A73E8)),
          useMaterial3: true,
        ),
        home: const RootView(),
      ),
    );
  }
}
