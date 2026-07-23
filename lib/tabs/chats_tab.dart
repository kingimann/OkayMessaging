import 'package:flutter/material.dart';

import '../models/chat.dart';
import '../relay/relay_config.dart';
import '../relay/relay_service.dart';
import '../screens/chat_screen.dart';
import '../state/chat_store.dart';
import '../theme/app_theme.dart';
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

  /// Pull-to-refresh: nudge the relay to re-sync delivery and presence.
  /// Local-first, so there's nothing to "download" — this just re-announces
  /// us to peers and re-subscribes if the connection dropped.
  Future<void> _refresh() async {
    final started = DateTime.now();
    if (RelayConfig.isEnabled) {
      try {
        await RelayService.instance.resync();
      } catch (_) {}
    }
    // Keep the spinner up long enough to feel intentional.
    final elapsed = DateTime.now().difference(started);
    if (elapsed < const Duration(milliseconds: 650)) {
      await Future<void>.delayed(const Duration(milliseconds: 650) - elapsed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = ChatStore.instance;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final allChats = store.chats;
        if (allChats.isEmpty) {
          return RefreshIndicator(
            onRefresh: _refresh,
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
      onRefresh: _refresh,
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
