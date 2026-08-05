import 'package:flutter/material.dart';

import '../models/chat.dart';
import '../state/chat_store.dart';
import '../widgets/chat_list_tile.dart';
import '../widgets/empty_state.dart';
import '../widgets/pull_to_refresh.dart';
import 'chat_screen.dart';

/// The Marketplace section of the chat list: conversations that exist
/// because of a listing — buyers asking, sellers answering — kept out of
/// the main list so trade never buries friends. Same rows, same chats,
/// one shelf over.
class MarketplaceChatsScreen extends StatelessWidget {
  const MarketplaceChatsScreen({super.key});

  void _showActions(BuildContext context, Chat chat) {
    final store = ChatStore.instance;
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.drive_file_move_outlined),
              title: const Text('Move to chats'),
              subtitle: const Text(
                  'For when a buyer or seller becomes a friend'),
              onTap: () {
                store.setMarketplace(chat.id, false);
                Navigator.of(sheetContext).pop();
              },
            ),
            ListTile(
              leading: const Icon(Icons.archive_outlined),
              title: const Text('Archive chat'),
              onTap: () {
                store.setArchived(chat.id, true);
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
      appBar: AppBar(title: const Text('Marketplace')),
      body: ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          final chats = store.marketplaceChats;
          if (chats.isEmpty) {
            return const EmptyState(
              icon: Icons.storefront_outlined,
              title: 'No marketplace chats',
              caption: 'Conversations started from a listing land here, '
                  'so buying and selling stays out of your chat list.',
            );
          }
          return PullToRefresh(
            child: ListView.separated(
              itemCount: chats.length,
              separatorBuilder: (_, __) => const Divider(
                height: 1,
                indent: 84,
                thickness: 0.4,
              ),
              itemBuilder: (context, index) {
                final chat = chats[index];
                return ChatListTile(
                  chat: chat,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => ChatScreen(chat: chat)),
                  ),
                  onLongPress: () => _showActions(context, chat),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
