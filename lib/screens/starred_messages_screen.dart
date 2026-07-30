import 'package:flutter/material.dart';

import '../state/chat_store.dart';
import '../theme/app_theme.dart';
import '../utils/date_formatter.dart';
import '../widgets/empty_state.dart';
import '../widgets/pull_to_refresh.dart';
import '../widgets/user_avatar.dart';

/// Lists every message the user has starred, grouped visually by chat.
class StarredMessagesScreen extends StatelessWidget {
  const StarredMessagesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = ChatStore.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Starred messages')),
      body: ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          final items = store.starredMessages();
          if (items.isEmpty) {
            return PullToRefresh.emptyState(child: const _EmptyState());
          }
          return PullToRefresh(
            child: ListView.separated(
              itemCount: items.length,
              separatorBuilder: (_, __) =>
                  const Divider(height: 1, indent: 72, thickness: 0.4),
              itemBuilder: (context, index) {
                final entry = items[index];
                return ListTile(
                  leading: UserAvatar(user: entry.chat.contact, radius: 22),
                  title: Row(
                    children: [
                      Expanded(
                        child: Text(
                          entry.message.isMe ? 'You' : entry.chat.contact.name,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      Text(
                        DateFormatter.chatListLabel(entry.message.time),
                        style: const TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ],
                  ),
                  subtitle: Text(entry.message.text,
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                  trailing: const Icon(Icons.star,
                      size: 16, color: AppColors.tealGreenDark),
                  onTap: () {},
                );
              },
            ),
          );
        },
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return const EmptyState(
      icon: Icons.star_border,
      title: 'No starred messages',
      caption: 'Tap and hold any message, then tap the star to keep it here.',
    );
  }
}
