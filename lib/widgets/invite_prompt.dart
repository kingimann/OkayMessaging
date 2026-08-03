import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../state/account_service.dart';

/// The gate in front of "chat with a number": a message here only ever
/// reaches somebody running this app, so starting a chat with a number the
/// directory has never heard of is composing into a void. Better to say so
/// and hand over an invite than to let a first message sit undelivered
/// forever.
///
/// Returns true when starting the chat is allowed. The check FAILS OPEN: an
/// unanswerable directory (offline, no relay, a numberless viewer whose
/// anon key cannot read it) allows the chat rather than blocking messaging
/// on a network hiccup — only a confident "nobody owns this number" stops
/// it.
Future<bool> allowChatWithNumber(BuildContext context, String number) async {
  final onApp = await AccountService.instance.isOnApp(number);
  if (onApp != false) return true;
  if (!context.mounted) return false;
  final invite = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('They\'re not on OkayMessenger'),
      content: Text('$number doesn\'t have an account, so a message can\'t '
          'reach them. Invite them — once they\'ve joined, you can chat.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Copy invite'),
        ),
      ],
    ),
  );
  if (invite == true && context.mounted) {
    final me = AppState.profile.value;
    final who = me.handle.isNotEmpty ? me.handle : me.name;
    Clipboard.setData(ClipboardData(
        text: 'Message me on OkayMessenger! I\'m $who. '
            'Grab the app and say hi.'));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Invite copied — paste it into a text to them')));
  }
  return false;
}
