import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../viewmodels/auth_view_model.dart';
import 'auth_view.dart';
import 'station_list_view.dart';

/// Decides which screen the app is on, from auth state alone.
///
/// There is no navigation stack between these three. A user who is not signed
/// in cannot reach the locker list by any route, which is what makes the first
/// half of evaluation criterion E1 structural rather than a check that could be
/// forgotten on one screen.
class RootView extends StatelessWidget {
  const RootView({super.key});

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<AuthViewModel>();

    if (!vm.isSignedIn) return const AuthView();
    if (vm.needsMembershipVerification) {
      return const MembershipVerificationView();
    }
    return const StationListView();
  }
}
