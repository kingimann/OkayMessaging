import 'package:flutter/material.dart';

import '../models/chat.dart';
import '../screens/chat_screen.dart';
import '../state/chat_store.dart';
import '../theme/app_theme.dart';
import '../widgets/chat_list_tile.dart';

/// The primary "Chats" tab: a clean, uncluttered list of all (non-archived)
/// conversations. Search and archived chats live in the app-bar menu.
class ChatsTab extends StatefulWidget {
  const ChatsTab({super.key});

  @override
  State<ChatsTab> createState() => _ChatsTabState();
}

class _ChatsTabState extends State<ChatsTab> {
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
        final chats = store.chats;
        if (chats.isEmpty) {
          return const _EmptyChats();
        }
        return ListView.separated(
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
        );
      },
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
