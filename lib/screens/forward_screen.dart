import 'package:flutter/material.dart';

import '../models/message.dart';
import '../state/chat_store.dart';
import '../theme/app_theme.dart';
import '../widgets/user_avatar.dart';

/// Lets the user pick one or more conversations to forward [text] into.
class ForwardScreen extends StatefulWidget {
  final String text;

  const ForwardScreen({super.key, required this.text});

  @override
  State<ForwardScreen> createState() => _ForwardScreenState();
}

class _ForwardScreenState extends State<ForwardScreen> {
  final Set<String> _selected = {};

  void _send() {
    final store = ChatStore.instance;
    final now = DateTime.now();
    for (final id in _selected) {
      store.addMessage(
        id,
        Message(
          id: 'fwd_${id}_${now.microsecondsSinceEpoch}',
          text: widget.text,
          time: DateTime.now(),
          isMe: true,
          status: MessageStatus.sent,
          forwarded: true,
        ),
      );
    }
    final count = _selected.length;
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    messenger.showSnackBar(
      SnackBar(
        content: Text('Forwarded to $count chat${count == 1 ? '' : 's'}'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final chats = ChatStore.instance.chats;
    return Scaffold(
      appBar: AppBar(
        title: Text(_selected.isEmpty
            ? 'Forward to...'
            : '${_selected.length} selected'),
      ),
      body: ListView.builder(
        itemCount: chats.length,
        itemBuilder: (context, index) {
          final chat = chats[index];
          final selected = _selected.contains(chat.id);
          return ListTile(
            leading: UserAvatar(user: chat.contact, radius: 24),
            title: Text(chat.contact.name,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            trailing: selected
                ? const Icon(Icons.check_circle, color: AppColors.tealGreenDark)
                : const Icon(Icons.circle_outlined, color: Colors.grey),
            onTap: () => setState(() {
              if (!_selected.remove(chat.id)) _selected.add(chat.id);
            }),
          );
        },
      ),
      floatingActionButton: _selected.isEmpty
          ? null
          : FloatingActionButton(
              backgroundColor: AppColors.tealGreenDark,
              onPressed: _send,
              child: const Icon(Icons.send, color: Colors.white),
            ),
    );
  }
}
