import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../viewmodels/auth_view_model.dart';

/// Sign in and registration on one screen (FR1).
///
/// The form is a [StatefulWidget] only because the text controllers have to
/// live somewhere. Every decision about what the form means stays in
/// [AuthViewModel].
class AuthView extends StatefulWidget {
  const AuthView({super.key});

  @override
  State<AuthView> createState() => _AuthViewState();
}

class _AuthViewState extends State<AuthView> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _membershipCode = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    _membershipCode.dispose();
    super.dispose();
  }

  Future<void> _submit(AuthViewModel vm) async {
    if (!_formKey.currentState!.validate()) return;

    if (vm.mode == AuthMode.signIn) {
      await vm.signIn(email: _email.text, password: _password.text);
    } else {
      await vm.register(
        email: _email.text,
        password: _password.text,
        displayName: _name.text,
        membershipCode: _membershipCode.text,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<AuthViewModel>();
    final theme = Theme.of(context);
    final registering = vm.mode == AuthMode.register;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(
                      Icons.lock_outline,
                      size: 48,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Smart Community Locker',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      registering
                          ? 'Create an account for your building.'
                          : 'Sign in to book a locker.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 24),

                    if (registering) ...[
                      TextFormField(
                        controller: _name,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: 'Full name',
                          border: OutlineInputBorder(),
                        ),
                        validator: (v) => (v == null || v.trim().isEmpty)
                            ? 'Enter your name.'
                            : null,
                      ),
                      const SizedBox(height: 12),
                    ],

                    TextFormField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: 'Email',
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) => (v == null || v.trim().isEmpty)
                          ? 'Enter your email.'
                          : null,
                    ),
                    const SizedBox(height: 12),

                    TextFormField(
                      controller: _password,
                      obscureText: true,
                      textInputAction: registering
                          ? TextInputAction.next
                          : TextInputAction.done,
                      decoration: const InputDecoration(
                        labelText: 'Password',
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) => (v == null || v.isEmpty)
                          ? 'Enter your password.'
                          : null,
                    ),

                    if (registering) ...[
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _membershipCode,
                        textCapitalization: TextCapitalization.characters,
                        autocorrect: false,
                        decoration: const InputDecoration(
                          labelText: 'Membership code',
                          helperText:
                              'From your building manager, e.g. WG-1041',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ],

                    if (vm.hasError) ...[
                      const SizedBox(height: 16),
                      _ErrorBanner(message: vm.error!),
                    ],

                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: vm.isBusy ? null : () => _submit(vm),
                      style: FilledButton.styleFrom(
                        // 48dp minimum touch target.
                        minimumSize: const Size.fromHeight(48),
                      ),
                      child: vm.isBusy
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(registering ? 'Create account' : 'Sign in'),
                    ),

                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: vm.isBusy
                          ? null
                          : () => vm.setMode(
                              registering ? AuthMode.signIn : AuthMode.register,
                            ),
                      child: Text(
                        registering
                            ? 'I already have an account'
                            : 'Create an account',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown when an account exists but has not been matched to the community
/// roll. E1 requires that such an account cannot book, so this screen stands
/// between sign-in and the locker list rather than being a dismissible notice.
class MembershipVerificationView extends StatefulWidget {
  const MembershipVerificationView({super.key});

  @override
  State<MembershipVerificationView> createState() =>
      _MembershipVerificationViewState();
}

class _MembershipVerificationViewState
    extends State<MembershipVerificationView> {
  final _code = TextEditingController();

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<AuthViewModel>();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Verify your membership'),
        actions: [
          TextButton(
            onPressed: vm.isBusy ? null : vm.signOut,
            child: const Text('Sign out'),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Hello ${vm.user?.displayName ?? ''}.',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                'Lockers are for residents only, so your account has to be '
                'matched to the community list before you can book.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _code,
                textCapitalization: TextCapitalization.characters,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Membership code',
                  helperText: 'From your building manager, e.g. WG-1041',
                  border: OutlineInputBorder(),
                ),
              ),
              if (vm.hasError) ...[
                const SizedBox(height: 16),
                _ErrorBanner(message: vm.error!),
              ],
              const SizedBox(height: 24),
              FilledButton(
                onPressed: vm.isBusy
                    ? null
                    : () => vm.verifyMembership(_code.text),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                child: vm.isBusy
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Verify'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
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
    );
  }
}
