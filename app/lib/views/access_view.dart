import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/door_event.dart';
import '../models/reservation.dart';
import '../repositories/access_token_repository.dart';
import '../repositories/locker_command_gateway.dart';
import '../viewmodels/access_view_model.dart';
import '../viewmodels/auth_view_model.dart';

/// Open a locker with a short-lived code (FR4, FR5).
///
/// The screen shows three things that change independently: the code and how
/// long it has left, what the server said about it, and what the door actually
/// did. They are three separate pieces of the layout for the same reason they
/// are three separate pieces of state.
class AccessView extends StatefulWidget {
  const AccessView({required this.reservation, super.key});

  final Reservation reservation;

  static Route<void> route(Reservation reservation) {
    return MaterialPageRoute<void>(
      builder: (context) => ChangeNotifierProvider<AccessViewModel>(
        create: (context) => AccessViewModel(
          tokens: context.read<AccessTokenRepository>(),
          gateway: context.read<LockerCommandGateway>(),
          reservation: reservation,
          userId: context.read<AuthViewModel>().user?.id ?? '',
        ),
        child: AccessView(reservation: reservation),
      ),
    );
  }

  @override
  State<AccessView> createState() => _AccessViewState();
}

class _AccessViewState extends State<AccessView> {
  final _pinController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<AccessViewModel>().requestToken();
    });
  }

  @override
  void dispose() {
    _pinController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<AccessViewModel>();

    return Scaffold(
      appBar: AppBar(title: Text('Open ${widget.reservation.compartmentId}')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (!vm.isOnline) const _OfflineBanner(),
            _CodePanel(vm: vm),
            const SizedBox(height: 16),
            _DoorPanel(vm: vm),
            if (vm.hasError) ...[
              const SizedBox(height: 16),
              _ProblemBanner(message: vm.error!, onDismiss: vm.clearError),
            ],
            const SizedBox(height: 24),
            _PinPanel(vm: vm, controller: _pinController),
          ],
        ),
      ),
    );
  }
}

/// The code itself, or whatever stands in its place.
class _CodePanel extends StatelessWidget {
  const _CodePanel({required this.vm});

  final AccessViewModel vm;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (vm.isRequesting) {
      return const SizedBox(
        height: 320,
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (vm.hasLiveToken) {
      return Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            // White on white, deliberately. A scanner needs the quiet zone and
            // a dark-themed background would break it.
            child: QrImageView(
              data: vm.qrPayload!,
              version: QrVersions.auto,
              size: 220,
              backgroundColor: Colors.white,
            ),
          ),
          const SizedBox(height: 16),
          _Countdown(vm: vm),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: vm.isBusy ? null : vm.openRemotely,
            icon: const Icon(Icons.lock_open),
            label: const Text('Open without scanning'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Hold the code up to the scanner, or use the button. Both go to '
              'the same place.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      );
    }

    // No live code. Three different situations, not one: the code was just
    // used, it ran out, or none has been asked for yet. They shared a single
    // layout until a demo screenshot showed the result — "Ready when you are,
    // get a code" sitting directly above "The door is open, opened with your
    // code".
    final (icon, title, detail, action) = vm.codeWasUsed
        ? (
            Icons.check_circle_outline,
            'Code used',
            'That code has done its job. Ask for another if you need to open '
                'the locker again.',
            'Get another code',
          )
        : vm.hasExpiredToken
        ? (
            Icons.timer_off_outlined,
            'That code has expired',
            'A code lasts 120 seconds and works once.',
            'Get a new code',
          )
        : (
            Icons.qr_code_2,
            'Ready when you are',
            'A code lasts 120 seconds and works once.',
            'Get a code',
          );

    return Column(
      children: [
        Icon(
          icon,
          size: 64,
          color: vm.codeWasUsed
              ? theme.colorScheme.primary
              : theme.colorScheme.outline,
        ),
        const SizedBox(height: 12),
        Text(title, style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          detail,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: vm.isBusy ? null : vm.requestToken,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          child: Text(action),
        ),
      ],
    );
  }
}

class _Countdown extends StatelessWidget {
  const _Countdown({required this.vm});

  final AccessViewModel vm;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final seconds = vm.remaining.inSeconds;
    // Turns red for the last fifteen seconds, when fetching a new code is the
    // better move than hurrying.
    final runningOut = seconds <= 15;

    return Column(
      children: [
        SizedBox(
          height: 56,
          width: 56,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CircularProgressIndicator(
                value: vm.remainingFraction,
                strokeWidth: 4,
                color: runningOut
                    ? theme.colorScheme.error
                    : theme.colorScheme.primary,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
              ),
              Text('$seconds', style: theme.textTheme.titleMedium),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Text('seconds left', style: theme.textTheme.bodySmall),
      ],
    );
  }
}

/// What the door actually did, which is not the same as what the server said.
class _DoorPanel extends StatelessWidget {
  const _DoorPanel({required this.vm});

  final AccessViewModel vm;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final event = vm.lastDoorEvent;

    final (icon, label, detail, colour) = switch (event) {
      null when vm.awaitingDoor => (
        Icons.hourglass_top,
        'Waiting for the locker',
        'The code was accepted. The door has not reported back yet.',
        theme.colorScheme.primary,
      ),
      null => (
        Icons.sensors,
        'No report from the locker',
        'The door will say what it did as soon as it does it.',
        theme.colorScheme.outline,
      ),
      final e when e.state == DoorState.open => (
        Icons.meeting_room,
        'The door is open',
        e.trigger == DoorTrigger.pin
            ? 'Opened with your backup PIN.'
            : 'Opened with your code.',
        theme.colorScheme.primary,
      ),
      final e when e.state == DoorState.faulty => (
        Icons.error_outline,
        'The door did not open',
        'The locker was told to open and the sensor says it did not move. '
            'This compartment has been taken out of service.',
        theme.colorScheme.error,
      ),
      final e => (
        Icons.door_front_door,
        'The door is closed',
        e.itemInside ? 'Something is inside.' : 'Nothing inside.',
        theme.colorScheme.outline,
      ),
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: colour),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: theme.textTheme.titleSmall),
                  const SizedBox(height: 2),
                  Text(detail, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The offline backup (QR4). Collapsed until asked for.
class _PinPanel extends StatelessWidget {
  const _PinPanel({required this.vm, required this.controller});

  final AccessViewModel vm;
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Backup PIN', style: theme.textTheme.titleSmall),
                ),
                if (vm.hasPin)
                  TextButton(
                    onPressed: vm.isPinVisible ? vm.hidePin : vm.showPin,
                    child: Text(vm.isPinVisible ? 'Hide' : 'Show mine'),
                  ),
              ],
            ),
            Text(
              'Works when the network is down. Unlike a code, it lasts as long '
              'as your booking, so keep it to yourself.',
              style: theme.textTheme.bodySmall,
            ),
            if (vm.pin != null) ...[
              const SizedBox(height: 12),
              Center(
                child: Text(
                  vm.pin!,
                  style: theme.textTheme.displaySmall?.copyWith(
                    letterSpacing: 8,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              maxLength: 4,
              decoration: const InputDecoration(
                labelText: 'Enter a PIN to open',
                border: OutlineInputBorder(),
                counterText: '',
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: vm.isBusy
                  ? null
                  : () => vm.openWithPin(controller.text),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              child: const Text('Open with PIN'),
            ),
          ],
        ),
      ),
    );
  }
}

class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            Icons.wifi_off,
            size: 20,
            color: theme.colorScheme.onTertiaryContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'No connection to the locker. Your backup PIN still works.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onTertiaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProblemBanner extends StatelessWidget {
  const _ProblemBanner({required this.message, required this.onDismiss});

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
