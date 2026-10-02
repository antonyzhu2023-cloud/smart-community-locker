import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/compartment.dart';
import '../models/locker_station.dart';
import '../viewmodels/station_list_view_model.dart';

/// Shows the stations a resident can book from.
///
/// The View only renders state and passes user actions up. Every decision —
/// what the filter means, when the list counts as empty, how errors read — is
/// in [StationListViewModel], which is why this file has no logic worth testing
/// and the ViewModel has plenty.
class StationListView extends StatefulWidget {
  const StationListView({super.key});

  @override
  State<StationListView> createState() => _StationListViewState();
}

class _StationListViewState extends State<StationListView> {
  @override
  void initState() {
    super.initState();
    // Load after the first frame so the ViewModel can call notifyListeners()
    // without rebuilding during a build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(context.read<StationListViewModel>().load());
    });
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<StationListViewModel>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Nearby lockers'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: vm.isLoading ? null : vm.load,
          ),
        ],
      ),
      body: Column(
        children: [
          _SizeFilterBar(selected: vm.sizeFilter, onChanged: vm.setSizeFilter),
          Expanded(child: _buildBody(context, vm)),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context, StationListViewModel vm) {
    if (vm.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (vm.hasError) {
      return _Message(
        icon: Icons.cloud_off,
        title: 'Could not load stations',
        detail: vm.error!,
        actionLabel: 'Try again',
        onAction: vm.load,
      );
    }

    if (vm.isEmpty) {
      return const _Message(
        icon: Icons.inbox_outlined,
        title: 'No free compartments',
        detail: 'Nothing matches that size right now. Try another size.',
      );
    }

    return RefreshIndicator(
      onRefresh: vm.load,
      child: ListView.builder(
        itemCount: vm.stations.length,
        itemBuilder: (context, i) => _StationTile(station: vm.stations[i]),
      ),
    );
  }
}

class _SizeFilterBar extends StatelessWidget {
  const _SizeFilterBar({required this.selected, required this.onChanged});

  final SizeClass? selected;
  final ValueChanged<SizeClass?> onChanged;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          FilterChip(
            label: const Text('All sizes'),
            selected: selected == null,
            onSelected: (_) => onChanged(null),
          ),
          const SizedBox(width: 8),
          for (final size in SizeClass.values) ...[
            FilterChip(
              label: Text(_label(size)),
              selected: selected == size,
              onSelected: (on) => onChanged(on ? size : null),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  static String _label(SizeClass size) => switch (size) {
    SizeClass.small => 'Small',
    SizeClass.medium => 'Medium',
    SizeClass.large => 'Large',
  };
}

class _StationTile extends StatelessWidget {
  const _StationTile({required this.station});

  final LockerStation station;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bookable = station.isBookable;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: ListTile(
        // 48dp minimum touch target, per the accessibility requirement in M1.
        minVerticalPadding: 12,
        leading: CircleAvatar(
          backgroundColor: bookable
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHighest,
          // An offline station shows no number. Its free count is a stale
          // figure from before the controller went quiet, and printing it next
          // to "Station offline" reads as though the locker is still usable.
          child: Text(
            station.status == StationStatus.offline
                ? '--'
                : '${station.freeCount}',
            style: theme.textTheme.titleMedium,
          ),
        ),
        title: Text(station.name),
        subtitle: Text(
          bookable
              ? '${station.freeCount} free of ${station.compartments.length}'
              : station.status == StationStatus.offline
              ? 'Station offline'
              : 'No free compartments',
        ),
        trailing: bookable ? const Icon(Icons.chevron_right) : null,
        enabled: bookable,
        onTap: bookable ? () {} : null, // Booking screen arrives in Sprint 1.
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    required this.detail,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String detail;
  final String? actionLabel;
  final VoidCallback? onAction;

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
            if (actionLabel != null) ...[
              const SizedBox(height: 16),
              FilledButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}
