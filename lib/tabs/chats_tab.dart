import 'package:flutter/material.dart';

import '../models/chat.dart';
import '../app_state.dart';
import '../models/user.dart';
import '../screens/chat_screen.dart';
import '../screens/contacts_on_app_screen.dart';
import '../screens/edit_profile_screen.dart';
import '../screens/find_people_screen.dart';
import '../state/chat_store.dart';
import '../state/contacts_sync.dart';
import '../state/onboarding_store.dart';
import '../theme/app_theme.dart';
import '../widgets/pull_to_refresh.dart';
import '../widgets/chat_list_tile.dart';

/// Quick filters shown as chips above the chat list, mirroring the familiar
/// All / Unread / Favourites / Groups controls.
enum ChatFilter {
  all,
  unread,
  favorites,
  groups;

  String get label => switch (this) {
        ChatFilter.all => 'All',
        ChatFilter.unread => 'Unread',
        ChatFilter.favorites => 'Favourites',
        ChatFilter.groups => 'Groups',
      };

  bool matches(Chat chat) => switch (this) {
        ChatFilter.all => true,
        ChatFilter.unread => chat.unreadCount > 0,
        ChatFilter.favorites => chat.isFavorite,
        ChatFilter.groups => chat.contact.isGroup,
      };
}

/// The primary "Chats" tab: a clean, uncluttered list of all (non-archived)
/// conversations. Search and archived chats live in the app-bar menu.
class ChatsTab extends StatefulWidget {
  const ChatsTab({super.key});

  /// Whether the filter chips are shown. Hidden by default to keep the chat
  /// list uncluttered; toggled from the Chats overflow menu.
  static final ValueNotifier<bool> filtersVisible = ValueNotifier<bool>(false);

  @override
  State<ChatsTab> createState() => _ChatsTabState();
}

class _ChatsTabState extends State<ChatsTab> {
  ChatFilter _filter = ChatFilter.all;
  void _openChat(Chat chat) {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => ChatScreen(chat: chat)));
  }

  void _showChatActions(Chat chat) {
    final store = ChatStore.instance;
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) {
        void act(void Function() action) {
          action();
          Navigator.of(sheetContext).pop();
        }

        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(
                    chat.isPinned ? Icons.push_pin : Icons.push_pin_outlined),
                title: Text(chat.isPinned ? 'Unpin chat' : 'Pin chat'),
                onTap: () => act(() => store.togglePin(chat.id)),
              ),
              ListTile(
                leading: Icon(
                    chat.isFavorite ? Icons.star : Icons.star_border_outlined),
                title: Text(chat.isFavorite
                    ? 'Remove from favourites'
                    : 'Add to favourites'),
                onTap: () => act(() => store.toggleFavorite(chat.id)),
              ),
              ListTile(
                leading:
                    Icon(chat.isMuted ? Icons.volume_up : Icons.volume_off),
                title: Text(chat.isMuted ? 'Unmute' : 'Mute notifications'),
                onTap: () => act(() => store.toggleMute(chat.id)),
              ),
              ListTile(
                leading: Icon(chat.unreadCount > 0
                    ? Icons.mark_chat_read
                    : Icons.mark_chat_unread),
                title: Text(
                    chat.unreadCount > 0 ? 'Mark as read' : 'Mark as unread'),
                onTap: () => act(() => chat.unreadCount > 0
                    ? store.markRead(chat.id)
                    : store.markUnread(chat.id)),
              ),
              ListTile(
                leading: const Icon(Icons.archive_outlined),
                title: const Text('Archive chat'),
                onTap: () => act(() => store.setArchived(chat.id, true)),
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.red),
                title: const Text('Delete chat',
                    style: TextStyle(color: Colors.red)),
                onTap: () => act(() => store.deleteChat(chat.id)),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = ChatStore.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([store, OnboardingStore.instance]),
      builder: (context, _) {
        final content = _content(context, store);
        if (OnboardingStore.instance.done) return content;
        return Column(
          children: [
            _GetStartedCard(onDismiss: OnboardingStore.instance.complete),
            Expanded(child: content),
          ],
        );
      },
    );
  }

  Widget _content(BuildContext context, ChatStore store) {
    return Builder(
      builder: (context) {
        final allChats = store.chats;
        if (allChats.isEmpty) {
          return RefreshIndicator(
            onRefresh: PullToRefresh.refreshApp,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: const [
                SizedBox(height: 120),
                _EmptyChats(),
              ],
            ),
          );
        }
        return ValueListenableBuilder<bool>(
          valueListenable: ChatsTab.filtersVisible,
          builder: (context, showFilters, _) {
            // When hidden, the list is unfiltered so nothing is silently
            // scoped away behind a collapsed bar.
            if (!showFilters) return _buildList(store, allChats);

            // Favourites only appears as a filter once something is
            // favourited, so the row stays uncluttered on a fresh account.
            final filters = <ChatFilter>[
              ChatFilter.all,
              ChatFilter.unread,
              if (store.hasFavorites) ChatFilter.favorites,
              ChatFilter.groups,
            ];
            // A previously-selected filter (e.g. Favourites) can disappear
            // from the row; fall back to All so the list never hides
            // everything.
            final active =
                filters.contains(_filter) ? _filter : ChatFilter.all;
            final chats = allChats.where(active.matches).toList();
            return Column(
              children: [
                _FilterBar(
                  filters: filters,
                  active: active,
                  onChanged: (f) => setState(() => _filter = f),
                ),
                Expanded(
                  child: chats.isEmpty
                      ? _EmptyFilter(filter: active)
                      : _buildList(store, chats),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildList(ChatStore store, List<Chat> chats) {
    return RefreshIndicator(
      onRefresh: PullToRefresh.refreshApp,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        // Clear the floating glass nav bar at the bottom.
        padding: const EdgeInsets.only(bottom: 96),
        itemCount: chats.length,
        separatorBuilder: (_, __) => const Divider(
          height: 1,
          indent: 84,
          thickness: 0.4,
        ),
        itemBuilder: (context, index) {
            final chat = chats[index];
            return Dismissible(
              key: ValueKey('chatrow_${chat.id}'),
              direction: DismissDirection.endToStart,
              background: Container(
                color: AppColors.tealGreenDark,
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 24),
                child: const Icon(Icons.archive, color: Colors.white),
              ),
              onDismissed: (_) {
                final messenger = ScaffoldMessenger.of(context);
                store.setArchived(chat.id, true);
                messenger.showSnackBar(SnackBar(
                  content: const Text('Chat archived'),
                  action: SnackBarAction(
                    label: 'Undo',
                    onPressed: () => store.setArchived(chat.id, false),
                  ),
                ));
              },
              child: ChatListTile(
                chat: chat,
                onTap: () => _openChat(chat),
                onLongPress: () => _showChatActions(chat),
              ),
            );
            },
          ),
        );
  }
}

/// A horizontal row of filter chips above the chat list.
class _FilterBar extends StatelessWidget {
  final List<ChatFilter> filters;
  final ChatFilter active;
  final ValueChanged<ChatFilter> onChanged;

  const _FilterBar({
    required this.filters,
    required this.active,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: filters.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final f = filters[i];
          return ChoiceChip(
            label: Text(f.label),
            selected: f == active,
            showCheckmark: false,
            onSelected: (_) => onChanged(f),
          );
        },
      ),
    );
  }
}

/// Shown when the active filter matches no conversations.
class _EmptyFilter extends StatelessWidget {
  final ChatFilter filter;
  const _EmptyFilter({required this.filter});

  @override
  Widget build(BuildContext context) {
    final grey = Colors.grey.shade500;
    final (IconData icon, String text) = switch (filter) {
      ChatFilter.unread => (Icons.mark_chat_read_outlined, 'No unread chats'),
      ChatFilter.favorites => (
          Icons.star_border,
          'No favourite chats yet'
        ),
      ChatFilter.groups => (Icons.groups_outlined, 'No group chats'),
      ChatFilter.all => (Icons.chat_bubble_outline, 'No chats'),
    };
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 120),
        Icon(icon, size: 56, color: grey),
        const SizedBox(height: 12),
        Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Colors.grey.shade600,
          ),
        ),
      ],
    );
  }
}

/// One-time "get started" nudge shown to new users above the chat list,
/// guiding them to set up a profile and find people. Dismissible; never
/// reappears once dismissed.
class _GetStartedCard extends StatelessWidget {
  final VoidCallback onDismiss;
  const _GetStartedCard({required this.onDismiss});

  void _push(BuildContext context, Widget screen) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('Welcome to OkayMessenger 👋',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 20),
                tooltip: 'Dismiss',
                onPressed: onDismiss,
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8, bottom: 8),
            child: Text('Get set up in a few taps.',
                style: TextStyle(
                    fontSize: 13, color: theme.colorScheme.onSurfaceVariant)),
          ),
          ValueListenableBuilder<AppUser>(
            valueListenable: AppState.profile,
            builder: (context, me, _) => _StepRow(
              icon: Icons.person_outline,
              title: 'Set up your profile',
              subtitle: 'Name, avatar emoji, username',
              // Done once they've picked a username or an avatar emoji.
              done: me.username.isNotEmpty || me.emoji.isNotEmpty,
              onTap: () => _push(context, const EditProfileScreen()),
            ),
          ),
          _StepRow(
            icon: Icons.alternate_email,
            title: 'Find people by username',
            subtitle: 'Search and start chatting',
            onTap: () => _push(context, const FindPeopleScreen()),
          ),
          if (ContactsSync.instance.supported)
            _StepRow(
              icon: Icons.contacts_outlined,
              title: 'Find your contacts',
              subtitle: 'See who already uses OkayMessenger',
              onTap: () => _push(context, const ContactsOnAppScreen()),
            ),
        ],
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool done;
  final VoidCallback onTap;
  const _StepRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.done = false,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          children: [
            Icon(icon, size: 22, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 14.5, fontWeight: FontWeight.w600)),
                  Text(subtitle,
                      style: TextStyle(
                          fontSize: 12.5, color: Colors.grey.shade600)),
                ],
              ),
            ),
            done
                ? const Icon(Icons.check_circle, size: 20, color: Colors.green)
                : const Icon(Icons.chevron_right,
                    size: 20, color: Colors.grey),
          ],
        ),
      ),
    );
  }
}

/// Friendly empty state for the chats list.
class _EmptyChats extends StatelessWidget {
  const _EmptyChats();

  @override
  Widget build(BuildContext context) {
    final grey = Colors.grey.shade500;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.chat_bubble_outline, size: 64, color: grey),
            const SizedBox(height: 16),
            Text(
              'No chats yet',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Tap the compose button to start a private,\nencrypted conversation.',
              textAlign: TextAlign.center,
              style: TextStyle(color: grey, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}
