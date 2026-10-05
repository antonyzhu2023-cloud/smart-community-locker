import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'repositories/auth_repository.dart';
import 'repositories/in_memory_auth_repository.dart';
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
/// Dependencies are provided here rather than reached for inside the classes
/// that use them. Milestone 1 ruled out the Singleton pattern for exactly this
/// reason: a static `getInstance()` cannot be replaced in a test, which would
/// put the 70% coverage target in QR6 out of reach.
///
/// Both repositories are still the in-memory implementations. Swapping them for
/// the Firebase ones is a change to this file and nothing else, which is the
/// claim Milestone 1 made for the repository layer and the thing Sprint 1 is
/// meant to put to the test.
class SclsApp extends StatelessWidget {
  const SclsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<LockerRepository>(create: (_) => InMemoryLockerRepository()),
        Provider<AuthRepository>(
          create: (_) => InMemoryAuthRepository(),
          dispose: (_, repo) {
            if (repo is InMemoryAuthRepository) repo.dispose();
          },
        ),
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
