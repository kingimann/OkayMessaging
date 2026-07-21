import 'package:flutter/material.dart';

import '../data/mock_data.dart';
import '../models/chat.dart';
import '../models/user.dart';
import '../state/chat_store.dart';
import '../widgets/user_avatar.dart';
import 'chat_screen.dart';

/// Contact picker shown from the Chats FAB. Start a chat with a sample contact
/// or with any phone number — everything is created and stored locally.
class NewChatScreen extends StatelessWidget {
  const NewChatScreen({super.key});

  void _openChat(BuildContext context, Chat chat) {
    // Replace this screen so back returns to the chats list, not the picker.
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => ChatScreen(chat: chat)),
    );
  }

  void _startChat(BuildContext context, AppUser contact) {
    final store = ChatStore.instance;
    final existing = store.chatWithContact(contact.id);
    final Chat chat;
    if (existing != null) {
      if (existing.isArchived) store.setArchived(existing.id, false);
      chat = existing;
    } else {
      chat = Chat(id: 'chat_${contact.id}', contact: contact, messages: const []);
      store.upsert(chat);
    }
    _openChat(context, chat);
  }

  Future<void> _startByNumber(BuildContext context) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Chat with a number'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.phone,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '+1 555 0199',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.of(dialogContext).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('Start'),
          ),
        ],
      ),
    );
    final number = result?.trim();
    if (number == null || number.isEmpty || !context.mounted) return;

    final store = ChatStore.instance;
    final existing = store.chatWithContact(number);
    final Chat chat;
    if (existing != null) {
      chat = existing;
    } else {
      final contact = AppUser(
        id: number,
        name: number,
        avatarColor: '#64B5F6',
        about: 'Available',
        phone: number,
      );
      chat = Chat(id: 'chat_$number', contact: contact, messages: const []);
      store.upsert(chat);
    }
    _openChat(context, chat);
  }

  @override
  Widget build(BuildContext context) {
    final contacts = MockData.contacts();
    return Scaffold(
      appBar: AppBar(title: const Text('New chat')),
      body: ListView(
        children: [
          _ActionTile(
            icon: Icons.dialpad,
            label: 'Chat with a number',
            onTap: () => _startByNumber(context),
          ),
          const _ActionTile(icon: Icons.group, label: 'New group'),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              'Contacts on Okay Messaging',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.grey,
              ),
            ),
          ),
          ...contacts.map(
            (c) => ListTile(
              leading: UserAvatar(user: c, radius: 24),
              title: Text(c.name,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle:
                  Text(c.about, maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => _startChat(context, c),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const _ActionTile({required this.icon, required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: CircleAvatar(
        radius: 24,
        backgroundColor: const Color(0xFF128C7E),
        child: Icon(icon, color: Colors.white),
      ),
      title: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
      onTap: onTap ?? () {},
    );
  }
}
