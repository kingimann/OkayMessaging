import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/two_step.dart';
import '../widgets/info_section.dart';
import 'settings_widgets.dart';

/// Manage two-step verification: enable with a 6-digit PIN and an optional
/// recovery email, change the PIN or email, or turn it off.
class TwoStepScreen extends StatelessWidget {
  const TwoStepScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Two-step verification')),
      body: ValueListenableBuilder<bool>(
        valueListenable: TwoStepVerification.instance.enabled,
        builder: (context, on, _) => ListView(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(
                children: [
                  Icon(on ? Icons.verified_user : Icons.shield_outlined,
                      color: on ? const Color(0xFF12B76A) : Colors.grey,
                      size: 34),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      on
                          ? 'Two-step verification is on. You\'ll need your PIN '
                              'to sign in on this device.'
                          : 'Add an extra PIN that\'s required whenever you '
                              'sign in — protection beyond your phone number.',
                      style: TextStyle(color: Colors.grey.shade700),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            if (!on)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: FilledButton.icon(
                  onPressed: () => _setup(context),
                  icon: const Icon(Icons.lock_outline),
                  label: const Text('Turn on'),
                ),
              )
            else ...[
              settingsSectionLabel(context, 'Manage'),
              InfoSection(children: [
                InfoTile(
                  leading: const Icon(Icons.pin_outlined),
                  title: 'Change PIN',
                  onTap: () => _setup(context, changing: true),
                ),
                InfoTile(
                  leading: const Icon(Icons.email_outlined),
                  title: 'Recovery email',
                  subtitle: TwoStepVerification.instance.email.isEmpty
                      ? 'Add an email in case you forget your PIN'
                      : TwoStepVerification.instance.email,
                  onTap: () => _editEmail(context),
                ),
                InfoTile(
                  leading: const Icon(Icons.no_encryption_gmailerrorred_outlined,
                      color: Colors.red),
                  title: 'Turn off two-step verification',
                  titleColor: Colors.red,
                  onTap: () => _disable(context),
                ),
              ]),
            ],
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Future<void> _setup(BuildContext context, {bool changing = false}) async {
    final result = await showDialog<({String pin, String email})>(
      context: context,
      builder: (_) => _PinDialog(withEmail: !changing),
    );
    if (result == null) return;
    await TwoStepVerification.instance.setPin(
      result.pin,
      recoveryEmail: changing ? null : result.email,
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(changing
            ? 'PIN changed'
            : 'Two-step verification turned on'),
      ));
    }
  }

  Future<void> _editEmail(BuildContext context) async {
    final controller = TextEditingController(
        text: TwoStepVerification.instance.email);
    final email = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Recovery email'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(
            hintText: 'you@example.com',
            helperText: 'Used to help you reset your PIN',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(controller.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    controller.dispose();
    if (email != null) {
      await TwoStepVerification.instance.setEmail(email);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Recovery email updated')),
        );
      }
    }
  }

  Future<void> _disable(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Turn off two-step verification?'),
        content: const Text(
            'You won\'t be asked for a PIN when signing in on this device.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child:
                  const Text('Turn off', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (ok == true) {
      await TwoStepVerification.instance.disable();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Two-step verification turned off')),
        );
      }
    }
  }
}

/// Collects a 6-digit PIN (with confirmation) and, optionally, a recovery
/// email. Owns its controllers so they dispose after the exit transition.
class _PinDialog extends StatefulWidget {
  final bool withEmail;
  const _PinDialog({required this.withEmail});

  @override
  State<_PinDialog> createState() => _PinDialogState();
}

class _PinDialogState extends State<_PinDialog> {
  final _pin = TextEditingController();
  final _confirm = TextEditingController();
  final _email = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _pin.dispose();
    _confirm.dispose();
    _email.dispose();
    super.dispose();
  }

  void _submit() {
    if (!TwoStepVerification.isValidPin(_pin.text)) {
      setState(() => _error = 'Enter a 6-digit PIN');
      return;
    }
    if (_pin.text != _confirm.text) {
      setState(() => _error = 'PINs don\'t match');
      return;
    }
    Navigator.of(context)
        .pop((pin: _pin.text, email: _email.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    Widget pinField(TextEditingController c, String label) => TextField(
          controller: c,
          obscureText: true,
          keyboardType: TextInputType.number,
          maxLength: 6,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(labelText: label, counterText: ''),
        );
    return AlertDialog(
      title: const Text('Set a 6-digit PIN'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          pinField(_pin, 'PIN'),
          pinField(_confirm, 'Confirm PIN'),
          if (widget.withEmail) ...[
            const SizedBox(height: 8),
            TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                labelText: 'Recovery email (optional)',
                hintText: 'you@example.com',
              ),
            ),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child:
                  Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel')),
        TextButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }
}
