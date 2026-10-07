import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/access_token.dart';
import '../models/reservation.dart';
import '../repositories/access_token_repository.dart';
import '../repositories/auth_repository.dart';
import '../viewmodels/auth_view_model.dart';
import '../viewmodels/handover_view_model.dart';

/// Give a booking to a neighbour (FR7).
///
/// The screen is built in two steps on purpose. The owner searches for the
/// neighbour and sees who they found before anything is given away. Handing a
/// locker to a mistyped address is not something a confirmation dialog can
/// undo.
class HandoverView extends StatefulWidget {
  const HandoverView({required this.reservation, super.key});

  final Reservation reservation;

  static Route<void> route(Reservation reservation) {
    return MaterialPageRoute<void>(
      builder: (context) => ChangeNotifierProvider<HandoverViewModel>(
        create: (context) => HandoverViewModel(
          tokens: context.read<AccessTokenRepository>(),
          auth: context.read<AuthRepository>(),
          reservation: reservation,
          ownerId: context.read<AuthViewModel>().user?.id ?? '',
        ),
        child: HandoverView(reservation: reservation),
      ),
    );
  }

  @override
  State<HandoverView> createState() => _HandoverViewState();
}

class _HandoverViewState extends State<HandoverView> {
  final _email = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<HandoverViewModel>().load();
    });
  }

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<HandoverViewModel>();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Give to a neighbour')),
      body: SafeArea(
        child: vm.isLoading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(
                    'Compartment ${widget.reservation.compartmentId}',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Your neighbour gets one code. It opens the locker once. '
                    'You keep your own access and you can take theirs back '
                    'until they use it.',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 24),

                  if (!vm.canHandOver)
                    const _Notice(
                      icon: Icons.block,
                      message:
                          'This booking is no longer active, so it cannot be '
                          'given to anyone.',
                    )
                  else ...[
                    _FindBox(vm: vm, controller: _email),
                    if (vm.found != null) ...[
                      const SizedBox(height: 16),
                      _ConfirmBox(vm: vm, onDone: () => _email.clear()),
                    ],
                  ],

                  if (vm.hasError) ...[
                    const SizedBox(height: 16),
                    _Message(
                      text: vm.error!,
                      background: theme.colorScheme.errorContainer,
                      foreground: theme.colorScheme.onErrorContainer,
                      onDismiss: vm.clearMessages,
                    ),
                  ],
                  if (vm.notice != null) ...[
                    const SizedBox(height: 16),
                    _Message(
                      text: vm.notice!,
                      background: theme.colorScheme.primaryContainer,
                      foreground: theme.colorScheme.onPrimaryContainer,
                      onDismiss: vm.clearMessages,
                    ),
                  ],

                  const SizedBox(height: 32),
                  Text('Given out', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  if (!vm.hasLiveHandover)
                    Text(
                      'Nobody else can open this locker.',
                      style: theme.textTheme.bodySmall,
                    )
                  else
                    for (final token in vm.liveHandovers)
                      _HandoverTile(token: token, vm: vm),
                ],
              ),
      ),
    );
  }
}

class _FindBox extends StatelessWidget {
  const _FindBox({required this.vm, required this.controller});

  final HandoverViewModel vm;
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: controller,
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
          enabled: !vm.isBusy,
          decoration: const InputDecoration(
            labelText: 'Neighbour’s email',
            helperText: 'They need an account and a membership code already.',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: vm.isBusy ? null : () => vm.findNeighbour(controller.text),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
          ),
          child: const Text('Find them'),
        ),
      ],
    );
  }
}

/// Step two. Who was found, and a button that actually gives the access away.
class _ConfirmBox extends StatelessWidget {
  const _ConfirmBox({required this.vm, required this.onDone});

  final HandoverViewModel vm;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final neighbour = vm.found!;

    return Card(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: theme.colorScheme.primaryContainer,
                  child: Text(_initials(neighbour.displayName)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        neighbour.displayName,
                        style: theme.textTheme.titleSmall,
                      ),
                      Text(neighbour.email, style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Not them',
                  onPressed: vm.isBusy ? null : vm.clearNeighbour,
                ),
              ],
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: vm.isBusy
                  ? null
                  : () async {
                      if (await vm.handOver()) onDone();
                    },
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              child: Text('Give ${_firstName(neighbour.displayName)} access'),
            ),
          ],
        ),
      ),
    );
  }

  static String _firstName(String name) => name.split(' ').first;

  static String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length == 1) return parts.first.characters.first.toUpperCase();
    return (parts.first.characters.first + parts.last.characters.first)
        .toUpperCase();
  }
}

class _HandoverTile extends StatelessWidget {
  const _HandoverTile({required this.token, required this.vm});

  final AccessToken token;
  final HandoverViewModel vm;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('One code given out', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 2),
                  Text(
                    'Not used yet. Opens the locker once.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: vm.isBusy ? null : () => vm.takeBack(token.id),
              child: const Text('Take back'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: theme.colorScheme.outline),
        const SizedBox(width: 8),
        Expanded(child: Text(message, style: theme.textTheme.bodyMedium)),
      ],
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.text,
    required this.background,
    required this.foreground,
    required this.onDismiss,
  });

  final String text;
  final Color background;
  final Color foreground;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(color: foreground),
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
