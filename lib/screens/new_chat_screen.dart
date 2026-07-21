import 'package:flutter/material.dart';

import '../data/mock_data.dart';
import '../models/chat.dart';
import '../models/user.dart';
import '../widgets/user_avatar.dart';
import 'chat_screen.dart';

/// Contact picker shown from the Chats FAB to start a new conversation.
class NewChatScreen extends StatelessWidget {
  const NewChatScreen({super.key});

  void _startChat(BuildContext context, AppUser contact) {
    final chat = Chat(
      id: 'new_${contact.id}',
      contact: contact,
      messages: const [],
    );
    // Replace this screen so back returns to the chats list, not the picker.
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => ChatScreen(chat: chat)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final contacts = MockData.contacts();
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('New chat'),
            Text(
              '${contacts.length} contacts',
              style: const TextStyle(fontSize: 12.5, color: Colors.white70),
            ),
          ],
        ),
        actions: [
          IconButton(icon: const Icon(Icons.search), onPressed: () {}),
        ],
      ),
      body: ListView(
        children: [
          const _ActionTile(icon: Icons.group, label: 'New group'),
          const _ActionTile(icon: Icons.person_add, label: 'New contact'),
          const _ActionTile(icon: Icons.groups, label: 'New community'),
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

  const _ActionTile({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: CircleAvatar(
        radius: 24,
        backgroundColor: const Color(0xFF128C7E),
        child: Icon(icon, color: Colors.white),
      ),
      title: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
      onTap: () {},
    );
  }
}
