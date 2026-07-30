import 'package:flutter/material.dart';

import '../models/chat.dart';
import '../models/user.dart';
import '../state/chat_store.dart';
import '../state/follow_store.dart';
import '../widgets/pull_to_refresh.dart';
import '../widgets/user_avatar.dart';
import 'chat_screen.dart';
import 'contact_info_screen.dart';

/// One place to grow your circle: add a friend by phone number and follow
/// (or unfollow) anyone you know, feeding the server timelines.
class PeopleScreen extends StatefulWidget {
  const PeopleScreen({super.key});

  @override
  State<PeopleScreen> createState() => _PeopleScreenState();
}

class _PeopleScreenState extends State<PeopleScreen> {
  final TextEditingController _number = TextEditingController();

  @override
  void dispose() {
    _number.dispose();
    super.dispose();
  }

  void _addFriend() {
    final number = _number.text.trim();
    if (number.isEmpty) return;
    final store = ChatStore.instance;
    final existing = store.chatWithContact(number);
    if (existing == null) {
      final contact = AppUser(
        id: number,
        name: number,
        avatarColor: '#64B5F6',
        about: 'Available',
        phone: number,
      );
      store.upsert(
          Chat(id: 'chat_$number', contact: contact, messages: const []));
    }
    _number.clear();
    FocusScope.of(context).unfocus();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(existing == null
          ? 'Added $number — say hi!'
          : 'They\'re already in your chats.'),
    ));
  }

  /// The follow key: username when they have one, phone digits otherwise.
  String _followKey(AppUser u) =>
      u.username.isNotEmpty ? u.username : u.phone;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('People')),
      body: ListenableBuilder(
        listenable:
            Listenable.merge([ChatStore.instance, FollowStore.instance]),
        builder: (context, _) {
          final people = ChatStore.instance.chats
              .map((c) => c.contact)
              .where((u) => !u.isGroup)
              .toList()
            ..sort((a, b) =>
                a.name.toLowerCase().compareTo(b.name.toLowerCase()));
          return PullToRefresh(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _number,
                          keyboardType: TextInputType.phone,
                          onSubmitted: (_) => _addFriend(),
                          decoration: const InputDecoration(
                            labelText: 'Add a friend by phone number',
                            hintText: '+1 555 0199',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      FilledButton(
                        onPressed: _addFriend,
                        child: const Text('Add'),
                      ),
                    ],
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 18, 16, 6),
                  child: Text('YOUR PEOPLE',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.6,
                          color: Colors.grey)),
                ),
                if (people.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text('No contacts yet — add a friend above.',
                        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  ),
                for (final u in people)
                  ListTile(
                    leading: UserAvatar(user: u, radius: 22),
                    title: Text(u.name,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(
                        u.handle.isNotEmpty ? u.handle : u.phone,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    trailing: _FollowButton(followKey: _followKey(u)),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => ContactInfoScreen(user: u))),
                    onLongPress: () {
                      final chat = ChatStore.instance.chatWithContact(u.id);
                      if (chat != null) {
                        Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => ChatScreen(chat: chat)));
                      }
                    },
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// A compact Follow / Following toggle.
class _FollowButton extends StatelessWidget {
  final String followKey;
  const _FollowButton({required this.followKey});

  @override
  Widget build(BuildContext context) {
    final following = FollowStore.instance.isFollowing(followKey);
    return following
        ? OutlinedButton(
            onPressed: () => FollowStore.instance.toggle(followKey),
            style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact),
            child: const Text('Following'),
          )
        : FilledButton.tonal(
            onPressed: () => FollowStore.instance.toggle(followKey),
            style:
                FilledButton.styleFrom(visualDensity: VisualDensity.compact),
            child: const Text('Follow'),
          );
  }
}
