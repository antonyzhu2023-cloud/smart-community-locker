import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/compartment.dart';
import '../models/reservation.dart';
import '../repositories/booking_repository.dart';
import '../repositories/locker_repository.dart';
import '../viewmodels/auth_view_model.dart';
import '../viewmodels/booking_view_model.dart';

/// Book one compartment at one station (FR3).
///
/// Reached from the station list. The ViewModel is created for this route and
/// thrown away with it, because a half-finished booking should not survive
/// leaving the screen.
class BookingView extends StatefulWidget {
  const BookingView({required this.stationId, super.key});

  final String stationId;

  /// Builds the route, including its own ViewModel. Keeping this next to the
  /// screen means callers do not have to know what it depends on.
  static Route<void> route(String stationId) {
    return MaterialPageRoute<void>(
      builder: (context) => ChangeNotifierProvider<BookingViewModel>(
        create: (context) => BookingViewModel(
          context.read<BookingRepository>(),
          context.read<LockerRepository>(),
        ),
        child: BookingView(stationId: stationId),
      ),
    );
  }

  @override
  State<BookingView> createState() => _BookingViewState();
}

class _BookingViewState extends State<BookingView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<BookingViewModel>().openStation(widget.stationId);
    });
  }

  String get _userId => context.read<AuthViewModel>().user?.id ?? '';

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<BookingViewModel>();

    return Scaffold(
      appBar: AppBar(title: Text(vm.station?.name ?? 'Book a locker')),
      body: SafeArea(child: _body(context, vm)),
    );
  }

  Widget _body(BuildContext context, BookingViewModel vm) {
    if (vm.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (vm.isConfirmed) {
      return _Receipt(booking: vm.confirmed!);
    }
    if (vm.station == null) {
      return _Centered(
        icon: Icons.cloud_off,
        title: 'Could not open that station',
        detail: vm.error ?? 'Try again from the list.',
      );
    }
    if (vm.isFull) {
      return const _Centered(
        icon: Icons.inbox_outlined,
        title: 'No lockers free here',
        detail: 'Every compartment at this station is in use. Try another one.',
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const _SectionTitle('Choose a locker'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final compartment in vm.availableCompartments)
              ChoiceChip(
                label: Text(
                  '${compartment.id}  ${_sizeLabel(compartment.size)}',
                ),
                selected: vm.selected?.id == compartment.id,
                onSelected: (on) =>
                    vm.selectCompartment(on ? compartment : null),
              ),
          ],
        ),

        const SizedBox(height: 24),
        const _SectionTitle('How long do you need it?'),
        Wrap(
          spacing: 8,
          children: [
            for (final option in BookingViewModel.stayOptions)
              ChoiceChip(
                label: Text(_stayLabel(option)),
                selected: vm.stay == option,
                onSelected: (_) => vm.setStay(option),
              ),
          ],
        ),

        const SizedBox(height: 24),
        const _SectionTitle('What is it for?'),
        Wrap(
          spacing: 8,
          children: [
            for (final purpose in ReservationPurpose.values)
              ChoiceChip(
                label: Text(purposeLabel(purpose)),
                selected: vm.purpose == purpose,
                onSelected: (_) => vm.setPurpose(purpose),
              ),
          ],
        ),

        if (vm.hasError) ...[
          const SizedBox(height: 24),
          _ProblemBanner(
            message: vm.error!,
            // The recovery Milestone 1 specified for a lost race: offer the
            // next free compartment in one tap rather than sending the user
            // back to the list to start again.
            actionLabel: vm.lostRace
                ? 'Take ${vm.lostRaceAlternative} instead'
                : null,
            onAction: vm.lostRace && !vm.isSubmitting
                ? () => vm.acceptAlternative(_userId)
                : null,
          ),
        ],

        const SizedBox(height: 32),
        FilledButton(
          onPressed: vm.canSubmit ? () => vm.submit(_userId) : null,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          child: vm.isSubmitting
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Book this locker'),
        ),
      ],
    );
  }
}

String _sizeLabel(SizeClass size) => switch (size) {
  SizeClass.small => 'Small',
  SizeClass.medium => 'Medium',
  SizeClass.large => 'Large',
};

String _stayLabel(Duration stay) {
  if (stay.inHours < 24) return '${stay.inHours} hours';
  final days = stay.inHours ~/ 24;
  return days == 1 ? '1 day' : '$days days';
}

String purposeLabel(ReservationPurpose purpose) => switch (purpose) {
  ReservationPurpose.parcel => 'Parcel',
  ReservationPurpose.handover => 'Hand-over',
  ReservationPurpose.storage => 'Storage',
};

/// Shown once a booking is confirmed. The form is gone: a confirmed booking is
/// changed from the bookings list, not by editing the form that made it.
class _Receipt extends StatelessWidget {
  const _Receipt({required this.booking});

  final Reservation booking;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final until = DateFormat('EEE d MMM, HH:mm').format(booking.endTime);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.check_circle_outline,
              size: 56,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text('Locker booked', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(
              'Compartment ${booking.compartmentId}',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text('Yours until $until', style: theme.textTheme.bodyMedium),
            const SizedBox(height: 4),
            Text(
              purposeLabel(booking.purpose),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 32),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(text, style: Theme.of(context).textTheme.titleSmall),
    );
  }
}

class _ProblemBanner extends StatelessWidget {
  const _ProblemBanner({
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.error_outline,
                size: 20,
                color: theme.colorScheme.onErrorContainer,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onErrorContainer,
                  ),
                ),
              ),
            ],
          ),
          if (actionLabel != null)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: onAction, child: Text(actionLabel!)),
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
