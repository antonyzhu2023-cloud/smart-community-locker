import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'repositories/access_token_repository.dart';
import 'repositories/auth_repository.dart';
import 'repositories/booking_repository.dart';
import 'repositories/in_memory_access_backend.dart';
import 'repositories/in_memory_auth_repository.dart';
import 'repositories/in_memory_booking_repository.dart';
import 'repositories/in_memory_locker_repository.dart';
import 'repositories/locker_command_gateway.dart';
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
  late final InMemoryAccessBackend _access;

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
    // Issuing credentials and deciding whether one opens a door are both the
    // server's job, so one object implements both interfaces. The app still
    // sees two, because the screens have no reason to know they are the same
    // thing, and the Firebase build will split them again.
    _access = InMemoryAccessBackend(
      lockers: _lockers,
      bookings: _bookings,
      // A cabinet does not answer in the same instant it is asked. Without this
      // the "waiting for the locker" state would never be visible, and FR5
      // exists because that state is real.
      //
      // Three seconds is the slow end of plausible rather than the typical
      // case: an MQTT round trip plus a solenoid plus a reed switch is usually
      // well under a second. It is set this high so the intermediate state can
      // be read and captured. Say so wherever a screenshot of it is used.
      doorReportDelay: const Duration(seconds: 3),
    );
  }

  @override
  void dispose() {
    _auth.dispose();
    _access.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<LockerRepository>.value(value: _lockers),
        Provider<AuthRepository>.value(value: _auth),
        Provider<BookingRepository>.value(value: _bookings),
        Provider<AccessTokenRepository>.value(value: _access),
        Provider<LockerCommandGateway>.value(value: _access),
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
