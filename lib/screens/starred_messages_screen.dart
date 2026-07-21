import 'package:flutter/material.dart';

import '../state/chat_store.dart';
import '../theme/app_theme.dart';
import '../utils/date_formatter.dart';
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
            return const _EmptyState();
          }
          return ListView.separated(
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
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.star_border, size: 72, color: Colors.grey.shade400),
          const SizedBox(height: 12),
          const Text('No starred messages',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              'Tap and hold any message, then tap the star to keep it here.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade600),
            ),
          ),
        ],
      ),
    );
  }
}
