import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

import '../app_state.dart';
import '../models/chat.dart';
import '../state/chat_store.dart';
import '../widgets/chat_list_tile.dart';
import '../widgets/empty_state.dart';
import '../widgets/pull_to_refresh.dart';
import 'chat_screen.dart';

/// First messages from people you've never talked to, held here until you
/// decide. Until a request is accepted its sender learns nothing — no read
/// receipts, no typing, no presence — and it appears in no list or search.
class MessageRequestsScreen extends StatelessWidget {
  const MessageRequestsScreen({super.key});

  void _accept(BuildContext context, Chat chat) {
    ChatStore.instance.acceptRequest(chat.id);
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${chat.contact.name} moved to your chats')));
  }

  void _block(BuildContext context, Chat chat) async {
    final messenger = ScaffoldMessenger.of(context);
    // Deleting after blocking: the block stops the next message, the delete
    // removes what they already put in front of you.
    AppState.setBlocked(chat.contact.phone, true);
    ChatStore.instance.deleteChat(chat.id);
    messenger.showSnackBar(SnackBar(
      content: Text('${chat.contact.name} blocked'),
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () => AppState.setBlocked(chat.contact.phone, false),
      ),
    ));
  }

  void _delete(BuildContext context, Chat chat) {
    // A plain delete is not a block: they can write again, and it will file
    // as a new request the same way.
    ChatStore.instance.deleteChat(chat.id);
  }

  void _showActions(BuildContext context, Chat chat) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.check_circle_outline),
              title: const Text('Accept'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _accept(context, chat);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete request'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _delete(context, chat);
              },
            ),
            ListTile(
              leading: const Icon(Icons.block, color: Colors.red),
              title:
                  const Text('Block', style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _block(context, chat);
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
      appBar: AppBar(title: const Text('Message requests')),
      body: ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          final requests = store.requests;
          if (requests.isEmpty) {
            return const EmptyState(
              icon: Icons.mark_email_unread_outlined,
              title: 'No message requests',
              caption: 'When someone you\'ve never talked to messages you, '
                  'it waits here for you to decide.',
            );
          }
          return PullToRefresh(
            child: ListView(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Text(
                    'They won\'t see that you\'ve read anything — or that '
                    'you\'re online — until you accept. Replying accepts.',
                    style: TextStyle(
                        fontSize: 12.5, color: AppColors.subtle(context)),
                  ),
                ),
                for (final chat in requests) ...[
                  ChatListTile(
                    chat: chat,
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => ChatScreen(chat: chat))),
                    onLongPress: () => _showActions(context, chat),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(84, 0, 16, 8),
                    child: Row(
                      children: [
                        FilledButton(
                          style: FilledButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 18),
                          ),
                          onPressed: () => _accept(context, chat),
                          child: const Text('Accept'),
                        ),
                        const SizedBox(width: 10),
                        OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            foregroundColor: Colors.red,
                          ),
                          onPressed: () => _block(context, chat),
                          child: const Text('Block'),
                        ),
                        const SizedBox(width: 10),
                        TextButton(
                          style: TextButton.styleFrom(
                              visualDensity: VisualDensity.compact),
                          onPressed: () => _delete(context, chat),
                          child: const Text('Delete'),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1, indent: 84, thickness: 0.4),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}
