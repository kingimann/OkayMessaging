import 'package:flutter/material.dart';

import '../config/backend_config.dart';
import '../data/mock_data.dart';
import '../models/chat.dart';
import '../models/user.dart';
import '../services/supabase_chat_service.dart';
import '../state/chat_store.dart';
import '../widgets/user_avatar.dart';
import 'chat_screen.dart';

/// Contact picker shown from the Chats FAB to start a new conversation. In
/// demo mode it lists sample contacts; with a backend it lists everyone who
/// has an account and opens a real conversation.
class NewChatScreen extends StatefulWidget {
  const NewChatScreen({super.key});

  @override
  State<NewChatScreen> createState() => _NewChatScreenState();
}

class _NewChatScreenState extends State<NewChatScreen> {
  late Future<List<AppUser>> _contactsFuture;

  @override
  void initState() {
    super.initState();
    _contactsFuture = BackendConfig.isConfigured
        ? SupabaseChatService.instance.contacts()
        : Future.value(MockData.contacts());
  }

  Future<void> _startChat(BuildContext context, AppUser contact) async {
    final store = ChatStore.instance;

    if (BackendConfig.isConfigured) {
      final convId =
          await SupabaseChatService.instance.startConversationWith(contact.id);
      if (!context.mounted) return;
      final chat = store.chatById(convId) ??
          Chat(id: convId, contact: contact, messages: const []);
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => ChatScreen(chat: chat)),
      );
      return;
    }

    // Reuse an existing conversation with this contact if there is one.
    final existing = store.chatWithContact(contact.id);
    final Chat chat;
    if (existing != null) {
      if (existing.isArchived) store.setArchived(existing.id, false);
      chat = existing;
    } else {
      chat = Chat(
        id: 'new_${contact.id}',
        contact: contact,
        messages: const [],
      );
      store.upsert(chat);
    }
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => ChatScreen(chat: chat)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('New chat')),
      body: FutureBuilder<List<AppUser>>(
        future: _contactsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final contacts = snapshot.data ?? const <AppUser>[];
          return ListView(
            children: [
              const _ActionTile(icon: Icons.group, label: 'New group'),
              const _ActionTile(icon: Icons.person_add, label: 'New contact'),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text(
                  contacts.isEmpty
                      ? 'No other accounts yet'
                      : 'Contacts on Okay Messaging',
                  style: const TextStyle(
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
                  subtitle: Text(c.about,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () => _startChat(context, c),
                ),
              ),
            ],
          );
        },
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
