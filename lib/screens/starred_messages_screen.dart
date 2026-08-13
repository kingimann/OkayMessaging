import 'package:flutter/material.dart';

import '../models/message.dart';
import '../state/chat_store.dart';
import '../state/community_store.dart';
import '../theme/app_theme.dart';
import '../utils/date_formatter.dart';
import '../widgets/empty_state.dart';
import '../widgets/pull_to_refresh.dart';
import '../widgets/user_avatar.dart';
import 'communities.dart';

/// One starred item, whichever source it came from — a 1:1/group chat
/// message or a channel message. The two sources have different "where did
/// this come from" shapes (a `Chat` vs a `Community`+`Channel`), so this is
/// the one type the screen actually renders against.
class _StarredItem {
  final Message message;
  final String subtitle;
  final Widget leading;
  final VoidCallback? onTap;

  const _StarredItem({
    required this.message,
    required this.subtitle,
    required this.leading,
    this.onTap,
  });
}

/// Lists every message the user has starred, grouped visually by chat.
class StarredMessagesScreen extends StatelessWidget {
  const StarredMessagesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Starred messages')),
      body: ListenableBuilder(
        listenable:
            Listenable.merge([ChatStore.instance, CommunityStore.instance]),
        builder: (context, _) {
          final chatItems = [
            for (final entry in ChatStore.instance.starredMessages())
              _StarredItem(
                message: entry.message,
                subtitle: entry.message.isMe ? 'You' : entry.chat.contact.name,
                leading: UserAvatar(user: entry.chat.contact, radius: 22),
              ),
          ];
          final channelItems = [
            for (final entry in CommunityStore.instance.starredChannelMessages())
              _StarredItem(
                message: entry.message,
                subtitle: '#${entry.channel.name} · ${entry.community.name}',
                leading: CircleAvatar(
                  radius: 22,
                  backgroundColor: Theme.of(context)
                      .colorScheme
                      .surfaceContainerHighest,
                  child: const Icon(Icons.tag),
                ),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ChannelScreen(
                    communityId: entry.community.id,
                    channelId: entry.channel.id,
                  ),
                )),
              ),
          ];
          final items = [...chatItems, ...channelItems]
            ..sort((a, b) => b.message.time.compareTo(a.message.time));
          if (items.isEmpty) {
            return PullToRefresh.emptyState(child: const _EmptyState());
          }
          return PullToRefresh(
            child: ListView.separated(
              itemCount: items.length,
              separatorBuilder: (_, __) =>
                  const Divider(height: 1, indent: 72, thickness: 0.4),
              itemBuilder: (context, index) {
                final item = items[index];
                return ListTile(
                  leading: item.leading,
                  title: Row(
                    children: [
                      Expanded(
                        child: Text(
                          item.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      Text(
                        DateFormatter.chatListLabel(item.message.time),
                        style: const TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ],
                  ),
                  subtitle: Text(item.message.text,
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                  trailing: Icon(Icons.star,
                      size: 16, color: AppColors.accentOn(context)),
                  onTap: item.onTap ?? () {},
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
