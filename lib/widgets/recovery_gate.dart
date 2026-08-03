import 'package:flutter/material.dart';

import '../crypto/double_ratchet.dart';
import '../crypto/identity_recovery.dart';
import '../crypto/key_exchange.dart';
import '../relay/relay_config.dart';
import '../relay/relay_service.dart';
import '../screens/recovery_code_screen.dart';
import '../state/session.dart';

/// X's rule for encrypted DMs, adopted whole: you don't message until your
/// recovery code exists. A fresh account CREATES one before its first send;
/// a returning device TYPES one in to get its old keys back. The reason is
/// timing — the only moment a key backup can still be made is before the
/// phone holding the only copy is gone, and "before the first message" is
/// the last gate everybody reliably walks through.
///
/// Stands in for the real conditions in tests — a build with no relay can
/// never reach the gated branch otherwise.
@visibleForTesting
bool? debugRecoveryGateNeeded;

/// The gate never fires where it has nothing to protect: no relay, no
/// signed-in account, or already squared away.
bool recoveryGateNeeded() =>
    debugRecoveryGateNeeded ??
    (RelayConfig.isEnabled &&
        Session.instance.user.value != null &&
        !IdentityRecovery.ready.value);

/// One proactive prompt per app run, for the moment a chat opens — so the
/// setup usually happens before anyone has typed a message they're now
/// holding. The SEND path still enforces; this is just better manners.
bool _promptedThisRun = false;
Future<void> maybePromptRecoverySetup(BuildContext context,
    {String? debugInbox}) async {
  if (_promptedThisRun || !recoveryGateNeeded()) return;
  _promptedThisRun = true;
  await ensureRecoveryReady(context, debugInbox: debugInbox);
}

@visibleForTesting
void resetRecoveryPromptForTest() => _promptedThisRun = false;

/// Blocks until the recovery code is squared away, walking whichever flow
/// the account needs. Returns true when messaging may proceed.
Future<bool> ensureRecoveryReady(BuildContext context,
    {String? debugInbox}) async {
  if (!recoveryGateNeeded()) return true;
  final inbox = debugInbox ??
      RelayService.digits(Session.instance.user.value?.phone ?? '');
  if (inbox.isEmpty) return true;
  final blob = await IdentityRecovery.fetch(inbox);
  if (!context.mounted) return false;
  final ok = blob == null
      ? await _createFlow(context, inbox)
      : await _restoreFlow(context, inbox, blob);
  if (ok) await IdentityRecovery.markReady();
  return ok;
}

/// A fresh account: the user chooses a 4–6 digit PIN, and the sealed
/// identity goes to the server under it before the first message leaves.
Future<bool> _createFlow(BuildContext context, String inbox) async {
  final create = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Create your recovery PIN'),
      content: const Text(
        'Messages here are end-to-end encrypted with keys that live only '
        'on this phone. Before your first message, choose the PIN that '
        'can bring those keys to a new phone — without it, losing this '
        'phone means losing every conversation on it.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Not now'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Choose PIN'),
        ),
      ],
    ),
  );
  if (create != true || !context.mounted) return false;
  return createPinBackup(context, inbox);
}

/// Chooses a PIN and stores the sealed identity under it. Shared by the
/// gate's create flow, the lost-PIN restart, and the sign-in screens.
Future<bool> createPinBackup(BuildContext context, String inbox) async {
  final pin = await showChoosePinDialog(context);
  if (pin == null || !context.mounted) return false;
  final kx = SecureKeyExchange.instance;
  if (!kx.isReady) await kx.load();
  final blob = IdentityRecovery.sealIdentity(kx.exportPrivate(), pin);
  final stored = await IdentityRecovery.store(inbox, blob);
  if (!context.mounted) return false;
  if (!stored) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('The backup could not be stored — check the '
            'connection and try again.')));
    return false;
  }
  return true;
}

/// A returning device: a sealed backup exists, so ask for the code that
/// opens it. "I lost my code" stays honest — a phone account can replace
/// the backup (old messages stay unreadable; the keys are gone), while a
/// numberless one cannot replace anonymously and keeps its current keys.
Future<bool> _restoreFlow(
    BuildContext context, String inbox, String blob) async {
  final result = await showDialog<String>(
    context: context,
    builder: (_) => RestorePinDialog(blob: blob),
  );
  if (result == null || !context.mounted) return false;
  if (result == 'lost') return _lostCodeFlow(context, inbox);
  // Anything else is the private key hex the dialog already validated
  // ('lost' can never be hex, so the sentinel cannot collide).
  await SecureKeyExchange.instance.adoptIdentity(result);
  // Sessions keyed under the identity being discarded die with it; fresh
  // ones form on the next exchange, against the restored keys.
  DoubleRatchet.instance.resetAllSessions();
  return true;
}

/// Asks for the PIN (or a legacy code) that opens [blob], validating in
/// place. Public because the numberless sign-in flow asks the same
/// question with the same rules.
///
/// A widget rather than a `showDialog` closure so the controller is
/// disposed when the dialog leaves the tree — disposing it as soon as
/// `showDialog` returns kills it while the route is still animating out.
/// Validation happens in place: a wrong code shows its error under the
/// field instead of closing and reopening the dialog.
class RestorePinDialog extends StatefulWidget {
  final String blob;
  const RestorePinDialog({super.key, required this.blob});

  @override
  State<RestorePinDialog> createState() => _RestorePinDialogState();
}

class _RestorePinDialogState extends State<RestorePinDialog> {
  final _code = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  void _tryRestore() {
    final hex = IdentityRecovery.openIdentity(
        widget.blob, IdentityRecovery.normalize(_code.text));
    if (hex == null) {
      setState(() => _error = 'That PIN doesn\'t open the backup.');
      return;
    }
    Navigator.of(context).pop(hex);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Enter your recovery PIN'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'This account has an encryption backup. Type the recovery '
            'PIN to bring your keys to this phone, so your conversations '
            'pick up where they left off.',
            style: TextStyle(fontSize: 13.5),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _code,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: 'Recovery PIN',
              hintText: '4–6 digits (or an old recovery code)',
              border: const OutlineInputBorder(),
              isDense: true,
              errorText: _error,
            ),
            onSubmitted: (_) => _tryRestore(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop('lost'),
          child: const Text('I lost my PIN'),
        ),
        FilledButton(
          onPressed: _tryRestore,
          child: const Text('Restore'),
        ),
      ],
    );
  }
}

Future<bool> _lostCodeFlow(BuildContext context, String inbox) async {
  if (IdentityRecovery.isNumberless(inbox)) {
    // An anonymous account's backup is first-write-wins on the server, so
    // there is nothing to replace it with. The phone keeps the keys it has;
    // messages sealed to the old ones stay sealed.
    final keep = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Keep this phone\'s keys?'),
        content: const Text(
          'Without the PIN, the old backup can\'t be opened — and this '
          'kind of account can\'t replace it. You can keep messaging with '
          'the keys this phone already has; messages sealed to the old '
          'keys stay unreadable.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Go back'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Keep current keys'),
          ),
        ],
      ),
    );
    return keep == true;
  }
  final replace = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Start over with a new PIN?'),
      content: const Text(
        'Without the PIN, the old backup can\'t be opened by anyone — '
        'that is what makes it safe. A new PIN backs up THIS phone\'s '
        'keys instead. Messages sealed to the old keys stay unreadable.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Go back'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('New PIN'),
        ),
      ],
    ),
  );
  if (replace != true || !context.mounted) return false;
  return createPinBackup(context, inbox);
}
