import 'package:flutter/material.dart';

import '../models/chat.dart';
import '../state/chat_store.dart';
import '../widgets/chat_list_tile.dart';
import 'chat_screen.dart';

/// Shows conversations the user has archived, with an unarchive action.
class ArchivedChatsScreen extends StatelessWidget {
  const ArchivedChatsScreen({super.key});

  void _showActions(BuildContext context, Chat chat) {
    final store = ChatStore.instance;
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.unarchive_outlined),
              title: const Text('Unarchive chat'),
              onTap: () {
                store.setArchived(chat.id, false);
                Navigator.of(sheetContext).pop();
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('Delete chat',
                  style: TextStyle(color: Colors.red)),
              onTap: () {
                store.deleteChat(chat.id);
                Navigator.of(sheetContext).pop();
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = ChatStore.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Archived')),
      body: ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          final archived = store.archivedChats;
          if (archived.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.archive_outlined,
                      size: 72, color: Colors.grey.shade400),
                  const SizedBox(height: 12),
                  const Text('No archived chats',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 40),
                    child: Text(
                      'Swipe a chat left, or long-press it, to archive it here.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey.shade600),
                    ),
                  ),
                ],
              ),
            );
          }
          return ListView.separated(
            itemCount: archived.length,
            separatorBuilder: (_, __) => const Divider(
              height: 1,
              indent: 84,
              thickness: 0.4,
            ),
            itemBuilder: (context, index) {
              final chat = archived[index];
              return ChatListTile(
                chat: chat,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => ChatScreen(chat: chat)),
                ),
                onLongPress: () => _showActions(context, chat),
              );
            },
          );
        },
      ),
    );
  }
}
