import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/reservation.dart';
import '../repositories/booking_repository.dart';
import '../viewmodels/auth_view_model.dart';
import '../viewmodels/my_bookings_view_model.dart';
import 'booking_view.dart' show purposeLabel;

/// The user's own bookings, with cancel and extend (FR3).
class MyBookingsView extends StatefulWidget {
  const MyBookingsView({super.key});

  static Route<void> route() {
    return MaterialPageRoute<void>(
      builder: (context) => ChangeNotifierProvider<MyBookingsViewModel>(
        create: (context) => MyBookingsViewModel(
          context.read<BookingRepository>(),
          context.read<AuthViewModel>().user?.id ?? '',
        ),
        child: const MyBookingsView(),
      ),
    );
  }

  @override
  State<MyBookingsView> createState() => _MyBookingsViewState();
}

class _MyBookingsViewState extends State<MyBookingsView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<MyBookingsViewModel>().load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<MyBookingsViewModel>();

    return Scaffold(
      appBar: AppBar(title: const Text('My bookings')),
      body: SafeArea(child: _body(vm)),
    );
  }

  Widget _body(MyBookingsViewModel vm) {
    if (vm.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (vm.isEmpty) {
      return const _Centered(
        icon: Icons.inbox_outlined,
        title: 'No bookings yet',
        detail: 'Book a locker from the station list and it will show up here.',
      );
    }

    final active = vm.active;
    final past = vm.past;

    return RefreshIndicator(
      onRefresh: vm.load,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          if (vm.hasError)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: _ErrorBanner(message: vm.error!, onDismiss: vm.clearError),
            ),
          if (active.isNotEmpty) ...[
            const _SectionHeader('Active'),
            for (final booking in active)
              _BookingTile(booking: booking, vm: vm, live: true),
          ],
          if (past.isNotEmpty) ...[
            const _SectionHeader('Finished'),
            for (final booking in past)
              _BookingTile(booking: booking, vm: vm, live: false),
          ],
        ],
      ),
    );
  }
}

class _BookingTile extends StatelessWidget {
  const _BookingTile({
    required this.booking,
    required this.vm,
    required this.live,
  });

  final Reservation booking;
  final MyBookingsViewModel vm;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final busy = vm.isWorkingOn(booking.id);
    final until = DateFormat('EEE d MMM, HH:mm').format(booking.endTime);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Compartment ${booking.compartmentId}',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                _StateChip(state: booking.state),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              live ? 'Until $until' : 'Ended $until',
              style: theme.textTheme.bodyMedium,
            ),
            Text(
              '${booking.stationId} · ${purposeLabel(booking.purpose)}',
              style: theme.textTheme.bodySmall,
            ),
            if (live)
              // Only one row is disabled while its own change is in flight,
              // rather than the whole list.
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (busy)
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                        height: 16,
                        width: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  else ...[
                    TextButton(
                      onPressed: () =>
                          vm.extend(booking.id, const Duration(hours: 2)),
                      child: const Text('Extend 2 h'),
                    ),
                    TextButton(
                      onPressed: () => _confirmCancel(context),
                      child: const Text('Cancel'),
                    ),
                  ],
                ],
              )
            else
              const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmCancel(BuildContext context) async {
    // Cancelling frees the compartment for someone else and cannot be undone,
    // so it asks first.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel this booking?'),
        content: Text(
          'Compartment ${booking.compartmentId} will be released for '
          'someone else to book.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Cancel booking'),
          ),
        ],
      ),
    );

    if (confirmed ?? false) await vm.cancel(booking.id);
  }
}

class _StateChip extends StatelessWidget {
  const _StateChip({required this.state});

  final ReservationState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (label, background) = switch (state) {
      ReservationState.confirmed => (
        'Confirmed',
        theme.colorScheme.primaryContainer,
      ),
      ReservationState.active => ('In use', theme.colorScheme.primaryContainer),
      ReservationState.overdue => ('Overdue', theme.colorScheme.errorContainer),
      ReservationState.completed => (
        'Completed',
        theme.colorScheme.surfaceContainerHighest,
      ),
      ReservationState.cancelled => (
        'Cancelled',
        theme.colorScheme.surfaceContainerHighest,
      ),
      ReservationState.expired => (
        'Expired',
        theme.colorScheme.surfaceContainerHighest,
      ),
      ReservationState.requested => (
        'Pending',
        theme.colorScheme.surfaceContainerHighest,
      ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(label, style: theme.textTheme.labelSmall),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(text, style: Theme.of(context).textTheme.titleSmall),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            tooltip: 'Dismiss',
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }
}

class _Centered extends StatelessWidget {
  const _Centered({
    required this.icon,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: theme.colorScheme.outline),
            const SizedBox(height: 16),
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}
