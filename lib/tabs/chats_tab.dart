import 'package:flutter/material.dart';

import '../models/chat.dart';
import '../screens/archived_chats_screen.dart';
import '../screens/chat_screen.dart';
import '../state/chat_store.dart';
import '../widgets/chat_list_tile.dart';

/// The primary "Chats" tab showing all (non-archived) conversations.
class ChatsTab extends StatelessWidget {
  const ChatsTab({super.key});

  void _openChat(BuildContext context, Chat chat) {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => ChatScreen(chat: chat)));
  }

  void _showChatActions(BuildContext context, Chat chat) {
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
        final chats = store.chats;
        if (chats.isEmpty && store.archivedCount == 0) {
          return const Center(child: Text('No chats yet'));
        }
        return ListView.separated(
          itemCount: chats.length + (store.archivedCount > 0 ? 1 : 0),
          separatorBuilder: (_, __) => const Divider(
            height: 1,
            indent: 84,
            thickness: 0.4,
          ),
          itemBuilder: (context, index) {
            if (store.archivedCount > 0 && index == 0) {
              return _ArchivedRow(count: store.archivedCount);
            }
            final chat = chats[index - (store.archivedCount > 0 ? 1 : 0)];
            return ChatListTile(
              chat: chat,
              onTap: () => _openChat(context, chat),
              onLongPress: () => _showChatActions(context, chat),
            );
          },
        );
      },
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
