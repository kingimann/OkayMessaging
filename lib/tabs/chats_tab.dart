import 'package:flutter/material.dart';

import '../models/chat.dart';
import '../screens/archived_chats_screen.dart';
import '../screens/chat_screen.dart';
import '../screens/chat_search_delegate.dart';
import '../state/chat_store.dart';
import '../theme/app_theme.dart';
import '../widgets/chat_list_tile.dart';

enum ChatFilter { all, unread, groups }

/// The primary "Chats" tab showing all (non-archived) conversations,
/// with All / Unread / Groups filter chips.
class ChatsTab extends StatefulWidget {
  const ChatsTab({super.key});

  @override
  State<ChatsTab> createState() => _ChatsTabState();
}

class _ChatsTabState extends State<ChatsTab> {
  ChatFilter _filter = ChatFilter.all;

  List<Chat> _apply(List<Chat> chats) {
    switch (_filter) {
      case ChatFilter.all:
        return chats;
      case ChatFilter.unread:
        return chats.where((c) => c.unreadCount > 0).toList();
      case ChatFilter.groups:
        return chats.where((c) => c.contact.isGroup).toList();
    }
  }

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
      listenable: store,
      builder: (context, _) {
        final chats = _apply(store.chats);
        final showArchived =
            _filter == ChatFilter.all && store.archivedCount > 0;
        return Column(
          children: [
            const _SearchPill(),
            _FilterBar(
              selected: _filter,
              onSelected: (f) => setState(() => _filter = f),
            ),
            Expanded(
              child: (chats.isEmpty && !showArchived)
                  ? Center(child: Text(_emptyLabel()))
                  : ListView.separated(
                      itemCount: chats.length + (showArchived ? 1 : 0),
                      separatorBuilder: (_, __) => const Divider(
                        height: 1,
                        indent: 84,
                        thickness: 0.4,
                      ),
                      itemBuilder: (context, index) {
                        if (showArchived && index == 0) {
                          return _ArchivedRow(count: store.archivedCount);
                        }
                        final chat = chats[index - (showArchived ? 1 : 0)];
                        return Dismissible(
                          key: ValueKey('chatrow_${chat.id}'),
                          direction: DismissDirection.endToStart,
                          background: Container(
                            color: AppColors.tealGreenDark,
                            alignment: Alignment.centerRight,
                            padding: const EdgeInsets.only(right: 24),
                            child:
                                const Icon(Icons.archive, color: Colors.white),
                          ),
                          onDismissed: (_) {
                            final messenger = ScaffoldMessenger.of(context);
                            store.setArchived(chat.id, true);
                            messenger.showSnackBar(SnackBar(
                              content: const Text('Chat archived'),
                              action: SnackBarAction(
                                label: 'Undo',
                                onPressed: () =>
                                    store.setArchived(chat.id, false),
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
            ),
          ],
        );
      },
    );
  }

  String _emptyLabel() {
    switch (_filter) {
      case ChatFilter.unread:
        return 'No unread chats';
      case ChatFilter.groups:
        return 'No groups';
      case ChatFilter.all:
        return 'No chats yet';
    }
  }
}

class _SearchPill extends StatelessWidget {
  const _SearchPill();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Material(
        color: isDark ? AppColors.darkAppBar : const Color(0xFFF0F2F3),
        borderRadius: BorderRadius.circular(24),
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: () => showSearch(
            context: context,
            delegate: ChatSearchDelegate(),
          ),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 11),
            child: Row(
              children: [
                Icon(Icons.search, size: 22, color: Colors.grey),
                SizedBox(width: 12),
                Text('Search',
                    style: TextStyle(color: Colors.grey, fontSize: 15)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FilterBar extends StatelessWidget {
  final ChatFilter selected;
  final ValueChanged<ChatFilter> onSelected;

  const _FilterBar({required this.selected, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    Widget chip(String label, ChatFilter filter) {
      final active = selected == filter;
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ChoiceChip(
          label: Text(label),
          selected: active,
          showCheckmark: false,
          selectedColor: AppColors.tealGreenDark.withValues(alpha: 0.18),
          labelStyle: TextStyle(
            color: active ? AppColors.tealGreenDark : null,
            fontWeight: active ? FontWeight.w600 : FontWeight.normal,
          ),
          onSelected: (_) => onSelected(filter),
        ),
      );
    }

    return Align(
      alignment: Alignment.centerLeft,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Row(
          children: [
            chip('All', ChatFilter.all),
            chip('Unread', ChatFilter.unread),
            chip('Groups', ChatFilter.groups),
          ],
        ),
      ),
    );
  }
}

class _ArchivedRow extends StatelessWidget {
  final int count;

  const _ArchivedRow({required this.count});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const SizedBox(
        width: 56,
        child: Icon(Icons.archive_outlined, color: Colors.grey),
      ),
      title:
          const Text('Archived', style: TextStyle(fontWeight: FontWeight.w600)),
      trailing: Text('$count',
          style: const TextStyle(color: Colors.grey, fontSize: 13)),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const ArchivedChatsScreen()),
      ),
    );
  }
}
