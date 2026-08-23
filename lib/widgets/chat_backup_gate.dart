import 'package:flutter/material.dart';

import '../crypto/identity_recovery.dart';
import '../relay/relay_config.dart';
import '../state/chat_store.dart';
import '../state/cloud_sync.dart';
import '../state/storage_store.dart';
import '../theme/app_theme.dart';

/// Asks, once, whether to protect the chat backup with a passphrase.
///
/// **WHY IT HAS TO BE ASKED AT ALL.** Everything else in the encrypted
/// backup rides a key derived from the account's own phone digits, which is
/// convenient and is not a secret — so chats are deliberately left out of it
/// ([CloudSync.chatBackupReady]). A passphrase is the only thing that can
/// seal them without handing the server something it could open. The result
/// was that conversations did not survive a reinstall for anybody who never
/// went looking in Settings, which is almost everybody: reported as "lots of
/// things don't save".
///
/// **What it delivers, now that there is a free allowance.** A passphrase
/// used to be necessary and NOT sufficient — storage had no free tier, so
/// [StorageStore.fits] refused every payload and setting one made a chat
/// backup possible and never working. [StorageStore.freeBytes] closed that,
/// so a passphrase is now the whole of what an ordinary account has to do.
/// The copy still stops short of promising a restore, because the allowance
/// is a real ceiling and a very large history can pass it. A test pins that
/// promise out of the file, so do not write it back in even in a comment.
///
/// The guarantee is unchanged — this is about ASKING, not about weakening
/// what the key is made of.
///
/// Three rules, and each is there because the obvious version fails:
///
/// * **Once per device, whatever the answer.** A prompt that returns every
///   launch is one people learn to dismiss without reading, and this
///   question — lose the passphrase, lose the backup — has to be read
///   properly exactly once.
/// * **Not before there is anything to lose.** A brand-new account has an
///   empty chat list, and asking somebody to invent and remember a secret to
///   protect nothing is how the question gets waved away.
/// * **Skippable.** Refusing to let somebody into their own conversations
///   until they think of a passphrase is a wall, and Settings → Chat backup
///   is the way in whenever they want it.
bool _promptedThisRun = false;

@visibleForTesting
void resetChatBackupPromptForTest() => _promptedThisRun = false;

/// One proactive prompt per app run, at the moment a chat opens — the point
/// at which somebody is looking at exactly the thing they would lose.
Future<void> maybePromptChatBackup(BuildContext context) async {
  if (_promptedThisRun) return;
  // Never where there is nothing to back up TO. A build with no relay has no
  // server behind the backup at all, so asking somebody to invent and
  // remember a passphrase there is asking them to protect a thing that
  // cannot happen — the same condition `recoveryGateNeeded` applies to the
  // recovery PIN one screen earlier.
  if (!RelayConfig.isEnabled) return;
  final sync = CloudSync.instance;
  if (!sync.chatBackupWorthAsking(ChatStore.instance.chats.length)) return;
  _promptedThisRun = true;
  await showChatBackupPrompt(context);
}

/// The prompt itself. Returns true when a passphrase was set.
Future<bool> showChatBackupPrompt(BuildContext context) async {
  final sync = CloudSync.instance;
  // THE PIN ROUTE ANSWERS THIS QUESTION WITHOUT ASKING IT. Somebody who
  // already set a recovery PIN has a secret this can ride, so making them
  // invent a second one is asking for a thing they do not need to have —
  // and the invented passphrase would be the WEAKER of the two (see
  // CloudSync.useRecoveryPin). One tap, and it says what it did.
  if (IdentityRecovery.ready.value) {
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _PinBackupSheet(),
    );
    await sync.noteAskedAboutChatBackup();
    if (ok != true) return false;
    return sync.useRecoveryPin(on: true);
  }
  final chosen = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => _ChatBackupSheet(),
  );
  // Asked either way: a "not now" is an answer, and re-asking it every
  // launch is what turns a real question into noise.
  await sync.noteAskedAboutChatBackup();
  if (chosen == null || chosen.isEmpty) return false;
  await sync.configure(passphrase: chosen, on: true);
  return true;
}

/// The one-tap version, for an account that already has a recovery PIN.
class _PinBackupSheet extends StatelessWidget {
  const _PinBackupSheet();

  @override
  Widget build(BuildContext context) {
    final subtle = AppColors.subtle(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Back up your chats',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(
                'Your servers, notes and places are backed up. Your '
                'CONVERSATIONS are not, because the key they would need is '
                'made from your phone number, which is not a secret.',
                style: TextStyle(fontSize: 13.5, height: 1.4, color: subtle),
              ),
              const SizedBox(height: 10),
              Text(
                'You already set a recovery PIN. Your chats can ride that — '
                'sealed with your identity key, which the PIN unlocks on a '
                'new phone. Nothing new to remember.',
                style: TextStyle(fontSize: 13.5, height: 1.4, color: subtle),
              ),
              const SizedBox(height: 10),
              Text(
                'Every account gets ${StorageStore.freeAllowanceLabel} of chat '
                'backup at no charge — plenty for text.',
                style: TextStyle(fontSize: 12.5, height: 1.35, color: subtle),
              ),
              const SizedBox(height: 12),
              // The same warning the passphrase sheet carries, for the same
              // reason: there is nobody to ask for it back.
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.lock_outline,
                      size: 16, color: Theme.of(context).colorScheme.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Forget the PIN and nobody can open the backup — not '
                      'even us.',
                      style: TextStyle(
                          fontSize: 12.5,
                          height: 1.35,
                          color: Theme.of(context).colorScheme.error),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48)),
                child: const Text('Use my recovery PIN'),
              ),
              const SizedBox(height: 6),
              Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Text('Not now', style: TextStyle(color: subtle)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChatBackupSheet extends StatefulWidget {
  @override
  State<_ChatBackupSheet> createState() => _ChatBackupSheetState();
}

class _ChatBackupSheetState extends State<_ChatBackupSheet> {
  final _pass = TextEditingController();
  bool _show = false;
  String? _error;

  @override
  void dispose() {
    _pass.dispose();
    super.dispose();
  }

  void _save() {
    final p = _pass.text.trim();
    // Six is what CloudSync itself treats as a real passphrase rather than
    // auto mode, so anything shorter would be accepted here and then quietly
    // do nothing — the worst possible outcome for a screen about not losing
    // things.
    if (p.length < 6) {
      setState(() => _error = 'At least 6 characters.');
      return;
    }
    Navigator.of(context).pop(p);
  }

  @override
  Widget build(BuildContext context) {
    final subtle = AppColors.subtle(context);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
            left: 20,
            right: 20,
            bottom: MediaQuery.of(context).viewInsets.bottom + 16),
        // Scrolls: this is a tall sheet with a text field in it, so on a
        // short phone the keyboard leaves it less room than it needs, and a
        // sheet that clips its own passphrase field is unusable rather than
        // untidy. (Caught by a widget test overflowing at 800x600 — a real
        // 320x568 phone would be far worse.)
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Set your backup passphrase',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(
                'Your backup is sealed with a key. Right now that key is made '
                'from your phone number, which is not a secret — so your '
                'servers, notes and places are backed up and your CONVERSATIONS '
                'are not. A passphrase is the key that can protect those too.',
                style: TextStyle(fontSize: 13.5, height: 1.4, color: subtle),
              ),
              const SizedBox(height: 10),
              // Stops short of promising a restore on purpose: the free
              // allowance is a real ceiling, so a very large history can pass
              // it. Naming the size lets somebody judge that for themselves
              // rather than finding out at the far end. A test pins the
              // promise out of this file, comments included.
              Text(
                'Every account gets ${StorageStore.freeAllowanceLabel} of chat '
                'backup at no charge — plenty for text. This passphrase is the '
                'part only you can set.',
                style: TextStyle(fontSize: 12.5, height: 1.35, color: subtle),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _pass,
                autofocus: true,
                obscureText: !_show,
                autocorrect: false,
                enableSuggestions: false,
                onSubmitted: (_) => _save(),
                decoration: InputDecoration(
                  labelText: 'Backup passphrase',
                  errorText: _error,
                  helperText: 'At least 6 characters',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(_show
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined),
                    tooltip: _show ? 'Hide' : 'Show',
                    onPressed: () => setState(() => _show = !_show),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              // SAID BEFORE THEY SET ONE, not after. This is the whole nature
              // of an end-to-end backup and the reason the app cannot simply
              // generate a passphrase and keep it: there is nobody to ask for
              // it back, and a screen that let somebody find that out later
              // would be the cruellest one in the app.
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.lock_outline,
                      size: 16, color: Theme.of(context).colorScheme.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Write it down somewhere safe. Nobody can reset it — not '
                      'even us — so a forgotten passphrase means the backup '
                      'can never be opened again.',
                      style: TextStyle(
                          fontSize: 12.5,
                          height: 1.35,
                          color: Theme.of(context).colorScheme.error),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              FilledButton(
                onPressed: _save,
                style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48)),
                child: const Text('Set passphrase'),
              ),
              const SizedBox(height: 6),
              Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text('Not now', style: TextStyle(color: subtle)),
                ),
              ),
              const SizedBox(height: 4),
              Center(
                child: Text('You can turn this on later in Settings.',
                    style: TextStyle(fontSize: 12, color: subtle)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
