import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../crypto/double_ratchet.dart';
import '../crypto/identity_recovery.dart';
import '../crypto/key_exchange.dart';
import '../relay/relay_service.dart';
import '../state/session.dart';
import '../theme/app_theme.dart';
import '../widgets/info_section.dart';

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
    setState(() => _busy = true);
    try {
      final kx = SecureKeyExchange.instance;
      if (!kx.isReady) await kx.load();
      final code = IdentityRecovery.mintCode();
      final blob = IdentityRecovery.sealIdentity(kx.exportPrivate(), code);
      final ok = await IdentityRecovery.store(inbox, blob);
      if (!mounted) return;
      if (!ok) {
        _say('The backup could not be stored. Check the connection and try '
            'again.');
        return;
      }
      // The work is done; the dialog is reading, not waiting. Ending the
      // busy state here also stops the restore button's spinner from
      // animating behind the dialog forever.
      setState(() {
        _backupExists = true;
        _busy = false;
      });
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Your recovery code'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Selectable AND monospaced: this is the one string in the app
              // somebody will write on paper.
              SelectableText(
                code,
                style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2),
              ),
              const SizedBox(height: 12),
              const Text(
                'Write it down somewhere safe. It is shown only this once, '
                'and it is the only thing that can restore your encryption '
                'on a new phone — nobody can recover it for you, including '
                'us. That is what keeps the backup unreadable to everyone '
                'but you.',
                style: TextStyle(fontSize: 13),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: code));
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Code copied')));
              },
              child: const Text('Copy'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('I saved it'),
            ),
          ],
        ),
      );
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
        _say('That code doesn\'t open the backup. Check it and try again.');
        return;
      }
      await SecureKeyExchange.instance.adoptIdentity(hex);
      // Every ratchet session was keyed under the identity just discarded;
      // fresh ones form on the next exchange, against the restored keys.
      DoubleRatchet.instance.resetAllSessions();
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
      appBar: AppBar(title: const Text('Encryption recovery code')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Your messages are sealed to keys that live only on this phone. '
            'A recovery code backs those keys up — encrypted so that only '
            'the code opens them — and brings them back on a new phone or '
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
              leading: const Icon(Icons.key_outlined),
              title: Text(_backupExists == true
                  ? 'Create a new code'
                  : 'Create recovery code'),
              subtitle: Text(_backupExists == true
                  ? 'Replaces the old backup — the old code stops working'
                  : 'Shown once. Write it down somewhere safe.'),
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
              labelText: 'Recovery code',
              hintText: 'XXXX-XXXX-XXXX-XXXX',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 10),
          FilledButton(
            onPressed: signedIn &&
                    !_busy &&
                    IdentityRecovery.normalize(_code.text).length == 16
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
