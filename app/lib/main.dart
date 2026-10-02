import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'repositories/in_memory_locker_repository.dart';
import 'repositories/locker_repository.dart';
import 'viewmodels/station_list_view_model.dart';
import 'views/station_list_view.dart';

void main() {
  runApp(const SclsApp());
}

/// Smart Community Locker System.
///
/// Dependencies are provided here rather than reached for inside the classes
/// that use them. Milestone 1 ruled out the Singleton pattern for exactly this
/// reason: a static `getInstance()` cannot be replaced in a test, which would
/// put the 70% coverage target in QR6 out of reach. The repository is injected,
/// so swapping [InMemoryLockerRepository] for the Firestore one later touches
/// only this file.
class SclsApp extends StatelessWidget {
  const SclsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<LockerRepository>(create: (_) => InMemoryLockerRepository()),
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
        home: const StationListView(),
      ),
    );
  }
}
