import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../crypto/double_ratchet.dart';
import '../crypto/identity_recovery.dart';
import '../crypto/key_exchange.dart';
import '../relay/relay_service.dart';
import '../state/session.dart';
import '../theme/app_theme.dart';
import '../widgets/info_section.dart';

/// Asks the user to choose (and confirm) their 4–6 digit recovery PIN —
/// the dialog every create path shares, so the rules and the warning
/// cannot drift between the settings screen and the first-message gate.
/// Returns the PIN, or null on cancel.
Future<String?> showChoosePinDialog(BuildContext context) => showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _ChoosePinDialog(),
    );

class _ChoosePinDialog extends StatefulWidget {
  const _ChoosePinDialog();

  @override
  State<_ChoosePinDialog> createState() => _ChoosePinDialogState();
}

class _ChoosePinDialogState extends State<_ChoosePinDialog> {
  final _pin = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _pin.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _submit() {
    final problem = IdentityRecovery.pinProblem(_pin.text);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    if (_pin.text.trim() != _confirm.text.trim()) {
      setState(() => _error = 'The PINs don\'t match.');
      return;
    }
    Navigator.of(context).pop(_pin.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Choose a recovery PIN'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '4–6 digits. It seals the backup of your encryption keys, and '
            'it is the only thing that opens it — if you forget it, nobody '
            'can recover it for you, including us.',
            style: TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _pin,
            autofocus: true,
            keyboardType: TextInputType.number,
            obscureText: true,
            maxLength: IdentityRecovery.maxPinLength,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: 'PIN',
              border: OutlineInputBorder(),
              isDense: true,
              counterText: '',
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _confirm,
            keyboardType: TextInputType.number,
            obscureText: true,
            maxLength: IdentityRecovery.maxPinLength,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: 'Confirm PIN',
              border: const OutlineInputBorder(),
              isDense: true,
              counterText: '',
              errorText: _error,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Save PIN'),
        ),
      ],
    );
  }
}

/// The recovery code: what makes encryption survive a new phone.
///
/// Without one, a reinstall mints a fresh identity and every message sealed
/// to the old one is gone — that is the "sealed to a key this device no
/// longer has" padlock. With one, the sealed identity waits on the server
/// and the code brings the SAME keys back, so peers never even notice the
/// device changed.
class RecoveryCodeScreen extends StatefulWidget {
  const RecoveryCodeScreen({super.key, this.debugInbox});

  /// Stands in for the signed-in account's digits in tests.
  final String? debugInbox;

  @override
  State<RecoveryCodeScreen> createState() => _RecoveryCodeScreenState();
}

class _RecoveryCodeScreenState extends State<RecoveryCodeScreen> {
  final _code = TextEditingController();
  bool _busy = false;

  /// Whether the server holds a sealed blob for this account. Null while
  /// unknown (loading, or unreachable).
  bool? _backupExists;

  String get _inbox =>
      widget.debugInbox ??
      RelayService.digits(Session.instance.user.value?.phone ?? '');

  @override
  void initState() {
    super.initState();
    _refreshStatus();
  }

  Future<void> _refreshStatus() async {
    final blob = await IdentityRecovery.fetch(_inbox);
    if (mounted) setState(() => _backupExists = blob != null);
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final inbox = _inbox;
    if (inbox.isEmpty) return;
    // A numberless backup is first-write-wins on the server (anonymous
    // writes can create but never replace), so offering "replace" would
    // offer a button that cannot work.
    if (_backupExists == true && IdentityRecovery.isNumberless(inbox)) {
      _say('This account\'s backup already exists and can\'t be replaced.');
      return;
    }
    final pin = await showChoosePinDialog(context);
    if (pin == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final kx = SecureKeyExchange.instance;
      if (!kx.isReady) await kx.load();
      final blob = IdentityRecovery.sealIdentity(kx.exportPrivate(), pin);
      final ok = await IdentityRecovery.store(inbox, blob);
      if (!mounted) return;
      if (!ok) {
        _say('The backup could not be stored. Check the connection and try '
            'again.');
        return;
      }
      setState(() => _backupExists = true);
      await IdentityRecovery.markReady();
      if (!mounted) return;
      _say('Recovery PIN saved. Your keys can now follow you to a new '
          'phone.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    final inbox = _inbox;
    final typed = IdentityRecovery.normalize(_code.text);
    if (inbox.isEmpty || typed.isEmpty) return;
    setState(() => _busy = true);
    try {
      final blob = await IdentityRecovery.fetch(inbox);
      if (!mounted) return;
      if (blob == null) {
        _say('No backup was found for this account.');
        return;
      }
      final hex = IdentityRecovery.openIdentity(blob, typed);
      if (hex == null) {
        _say('That PIN doesn\'t open the backup. Check it and try again.');
        return;
      }
      await SecureKeyExchange.instance.adoptIdentity(hex);
      // Every ratchet session was keyed under the identity just discarded;
      // fresh ones form on the next exchange, against the restored keys.
      DoubleRatchet.instance.resetAllSessions();
      await IdentityRecovery.markReady();
      if (!mounted) return;
      _code.clear();
      _say('Encryption restored. Messages sealed to this account\'s '
          'original keys can be read again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _say(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  @override
  Widget build(BuildContext context) {
    final signedIn = _inbox.isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('Encryption recovery PIN')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Your messages are sealed to keys that live only on this phone. '
            'A recovery PIN backs those keys up — encrypted so that only '
            'the PIN opens them — and brings them back on a new phone or '
            'after a reinstall, so old conversations stay readable and '
            'nobody sees a key change.',
            style: TextStyle(color: AppColors.subtle(context), fontSize: 13.5),
          ),
          const SizedBox(height: 8),
          Text(
            _backupExists == null
                ? 'Checking for an existing backup…'
                : _backupExists == true
                    ? 'A sealed backup exists for this account.'
                    : 'No backup yet.',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 16),
          InfoSection(children: [
            ListTile(
              leading: const Icon(Icons.pin_outlined),
              title: Text(_backupExists == true
                  ? 'Choose a new PIN'
                  : 'Create recovery PIN'),
              subtitle: Text(_backupExists == true
                  ? 'Replaces the old backup — the old PIN stops working'
                  : '4–6 digits only you know'),
              enabled: signedIn && !_busy,
              onTap: _create,
            ),
          ]),
          const SizedBox(height: 20),
          Text('RESTORE ON THIS PHONE',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                  color: AppColors.subtle(context))),
          const SizedBox(height: 8),
          TextField(
            controller: _code,
            enabled: signedIn && !_busy,
            textCapitalization: TextCapitalization.characters,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Recovery PIN',
              hintText: '4–6 digits (or an old recovery code)',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 10),
          FilledButton(
            onPressed: signedIn &&
                    !_busy &&
                    IdentityRecovery.normalize(_code.text).length >=
                        IdentityRecovery.minPinLength
                ? _restore
                : null,
            child: _busy
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Restore encryption'),
          ),
          const SizedBox(height: 10),
          Text(
            signedIn
                ? 'Restoring replaces this phone\'s keys with the backed-up '
                    'ones. Conversations pick up where the old phone left '
                    'off within a message or two.'
                : 'Sign in first — the backup belongs to an account.',
            style: TextStyle(fontSize: 12, color: AppColors.subtle(context)),
          ),
        ],
      ),
    );
  }
}
