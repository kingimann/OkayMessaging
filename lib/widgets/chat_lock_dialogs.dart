import 'package:flutter/material.dart';

import '../state/chat_lock.dart';
import '../theme/app_theme.dart';

/// The prompts for putting a password on a conversation and getting past one.
///
/// Kept together because the wording is the feature. A lock somebody sets
/// without understanding that forgetting the password costs them the chat is
/// a trap, and a hidden chat with no visible way back is a trap twice over —
/// so both dialogs say the consequence before the button that causes it.

/// Asks for a new password for [chatId], twice, plus whether to hide it.
/// Returns true when the chat ended up locked.
Future<bool> askToLockChat(BuildContext context, String chatId,
    {required String chatName}) async {
  final first = TextEditingController();
  final second = TextEditingController();
  var hide = false;
  var error = '';
  var busy = false;

  final ok = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setState) => AlertDialog(
        title: const Text('Lock this chat'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'This chat gets its own password. It is not your app PIN, and '
                'it is not shared with any other locked chat.',
                style:
                    TextStyle(fontSize: 13.5, color: AppColors.subtle(dialogContext)),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: first,
                obscureText: true,
                autofocus: true,
                decoration: const InputDecoration(
                    labelText: 'Password', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: second,
                obscureText: true,
                decoration: const InputDecoration(
                    labelText: 'Repeat password',
                    border: OutlineInputBorder()),
              ),
              const SizedBox(height: 6),
              CheckboxListTile(
                value: hide,
                onChanged: busy ? null : (v) => setState(() => hide = v ?? false),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('Also hide it from the chat list'),
                subtitle: Text(
                  'It disappears completely. The only way back is typing this '
                  'password into chat search — there is no row to tap and no '
                  'list of hidden chats anywhere.',
                  style: TextStyle(
                      fontSize: 12, color: AppColors.subtle(dialogContext)),
                ),
              ),
              // Said before the button, not after it. Nothing recovers a
              // forgotten password: there is no account behind this and no
              // reset to send anywhere.
              Text(
                'If you forget it, $chatName stays on this device and cannot '
                'be opened. Nothing can reset it.',
                style: TextStyle(
                    fontSize: 12.5,
                    height: 1.4,
                    color: Theme.of(dialogContext).colorScheme.error),
              ),
              if (error.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(error,
                    style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(dialogContext).colorScheme.error)),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed:
                busy ? null : () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: busy
                ? null
                : () async {
                    final a = first.text;
                    if (a.length < 4) {
                      setState(() => error = 'At least 4 characters.');
                      return;
                    }
                    if (a != second.text) {
                      setState(() => error = 'The two do not match.');
                      return;
                    }
                    setState(() {
                      busy = true;
                      error = '';
                    });
                    await ChatLock.instance.lock(chatId, a, hidden: hide);
                    if (dialogContext.mounted) {
                      Navigator.of(dialogContext).pop(true);
                    }
                  },
            child: Text(busy ? 'Locking…' : 'Lock'),
          ),
        ],
      ),
    ),
  );
  first.dispose();
  second.dispose();
  return ok ?? false;
}

/// Asks for [chatId]'s password. Returns true when it was right.
///
/// [remove] turns this into "unlock permanently" rather than "open once" —
/// same question, different consequence, so it says which.
Future<bool> askForChatPassword(BuildContext context, String chatId,
    {required String chatName, bool remove = false}) async {
  final field = TextEditingController();
  var error = '';
  var busy = false;

  final ok = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setState) => AlertDialog(
        title: Text(remove ? 'Remove the lock' : chatName),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              remove
                  ? 'Enter this chat\'s password to take the lock off it.'
                  : 'This chat is locked. Enter its password to open it.',
              style: TextStyle(
                  fontSize: 13.5, color: AppColors.subtle(dialogContext)),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: field,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(
                  labelText: 'Password', border: OutlineInputBorder()),
            ),
            if (error.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(error,
                  style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(dialogContext).colorScheme.error)),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed:
                busy ? null : () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: busy
                ? null
                : () async {
                    setState(() {
                      busy = true;
                      error = '';
                    });
                    final lock = ChatLock.instance;
                    final good = remove
                        ? await lock.removeLock(chatId, field.text)
                        : await lock.open(chatId, field.text);
                    if (!dialogContext.mounted) return;
                    if (good) {
                      Navigator.of(dialogContext).pop(true);
                    } else {
                      // No count, no lockout, no hint about how close it was.
                      setState(() {
                        busy = false;
                        error = 'That is not the password for this chat.';
                      });
                    }
                  },
            child: Text(busy ? 'Checking…' : (remove ? 'Remove' : 'Open')),
          ),
        ],
      ),
    ),
  );
  field.dispose();
  return ok ?? false;
}
