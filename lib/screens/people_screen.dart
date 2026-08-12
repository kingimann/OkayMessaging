import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models/chat.dart';
import '../models/user.dart';
import '../state/chat_store.dart';
import '../state/follow_store.dart';
import '../state/session.dart';
import '../widgets/empty_state.dart';
import '../widgets/invite_prompt.dart';
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

  Future<void> _addFriend() async {
    final number = _number.text.trim();
    if (number.isEmpty) return;
    final store = ChatStore.instance;
    if (store.isOwnNumber(number, myPhone: Session.instance.user.value?.phone)) {
      store.noteToSelfChat(myAvatarColor: AppState.profile.value.avatarColor);
      _number.clear();
      FocusScope.of(context).unfocus();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text("That's your own number — see Note to self in Chats.")));
      return;
    }
    final existing = store.chatWithContact(number);
    if (existing == null) {
      // Same gate as "chat with a number": a number the directory has
      // never heard of gets an invite, not a chat that cannot deliver.
      if (!await allowChatWithNumber(context, number)) return;
      if (!mounted) return;
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
                  const EmptyState(
                    icon: Icons.person_add_alt_outlined,
                    title: 'No contacts yet',
                    caption: 'Add a friend above by their username or number, '
                        'and they\'ll show up here.',
                    compact: true,
                  ),
                for (final u in people)
                  ListTile(
                    leading: UserAvatar(user: u, radius: 22),
                    title: Row(
                      children: [
                        Flexible(
                          child: Text(u.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600)),
                        ),
                        if (u.isBusiness) ...[
                          const SizedBox(width: 4),
                          Icon(Icons.storefront_outlined,
                              size: 15,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant),
                        ],
                      ],
                    ),
                    subtitle: Text(
                        u.isBusiness && u.businessCategory.trim().isNotEmpty
                            ? '${u.businessCategory.trim()} · '
                                '${u.handle.isNotEmpty ? u.handle : u.phone}'
                            : (u.handle.isNotEmpty ? u.handle : u.phone),
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
