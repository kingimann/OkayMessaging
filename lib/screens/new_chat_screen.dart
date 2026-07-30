import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../data/mock_data.dart';
import '../models/chat.dart';
import '../models/user.dart';
import '../state/chat_store.dart';
import '../state/contacts_sync.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/app_shell.dart';
import '../widgets/pull_to_refresh.dart';
import '../widgets/user_avatar.dart';
import 'chat_screen.dart';
import 'contacts_on_app_screen.dart';
import 'create_group_screen.dart';
import 'find_people_screen.dart';

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
      chat =
          Chat(id: 'chat_${contact.id}', contact: contact, messages: const []);
      store.upsert(chat);
    }
    _openChat(context, chat);
  }

  Future<void> _startByNumber(BuildContext context) async {
    final result = await showAppTextPrompt(
      context,
      icon: Icons.dialpad,
      title: 'Chat with a number',
      hint: '+1 555 0199',
      confirmLabel: 'Start',
      keyboardType: TextInputType.phone,
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

  /// Opens (or creates) the private notes chat with yourself: a place for
  /// reminders, links, and drafts. Nothing leaves the device — the "peer"
  /// is you, so the relay never delivers it anywhere else.
  void _openNoteToSelf(BuildContext context) {
    final store = ChatStore.instance;
    final me = AppState.profile.value;
    final existing = store.chatWithContact('self');
    final Chat chat;
    if (existing != null) {
      chat = existing;
    } else {
      chat = Chat(
        id: 'chat_self',
        contact: AppUser(
          id: 'self',
          name: 'Note to self',
          avatarColor: me.avatarColor,
          about: 'Your private notes',
          phone: '',
          emoji: '📝',
        ),
        messages: const [],
      );
      store.upsert(chat);
    }
    _openChat(context, chat);
  }

  @override
  Widget build(BuildContext context) {
    // Sample contacts are dev/test-only; a real install starts empty.
    final contacts = kReleaseMode ? <AppUser>[] : MockData.contacts();
    return Scaffold(
      appBar: AppBar(
          automaticallyImplyLeading: false,
          leading: const SidebarButton(),
          title: const Text('New chat')),
      body: PullToRefresh(
        child: ListView(
          children: [
            _ActionTile(
              icon: Icons.edit_note,
              label: 'Note to self',
              onTap: () => _openNoteToSelf(context),
            ),
            _ActionTile(
              icon: Icons.alternate_email,
              label: 'Find people by username',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const FindPeopleScreen()),
              ),
            ),
            if (ContactsSync.instance.supported)
              _ActionTile(
                icon: Icons.contacts_outlined,
                label: 'Find contacts on OkayMessenger',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                      builder: (_) => const ContactsOnAppScreen()),
                ),
              ),
            _ActionTile(
              icon: Icons.dialpad,
              label: 'Chat with a number',
              onTap: () => _startByNumber(context),
            ),
            _ActionTile(
              icon: Icons.group,
              label: 'New group',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const CreateGroupScreen()),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                'Contacts on OkayMessenger',
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
