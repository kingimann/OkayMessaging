import 'package:flutter/material.dart';

import '../models/chat.dart';
import '../state/call_log.dart';
import '../state/call_service.dart';
import '../state/chat_store.dart';
import '../state/feed_store.dart';
import '../screens/chat_screen.dart';
import '../screens/feed_screen.dart';
import '../utils/date_formatter.dart';
import '../widgets/pull_to_refresh.dart';
import '../widgets/user_avatar.dart';

/// What the notifications list is scoped to.
enum _Filter { all, messages, calls, servers }

/// The Notifications tab: everything that happened while you were away —
/// unread messages, missed calls, and new server posts — built purely from
/// real local state (no invented activity). Filterable, with mark-all-read
/// and swipe-to-clear.
class ActivityTab extends StatefulWidget {
  const ActivityTab({super.key});

  @override
  State<ActivityTab> createState() => _ActivityTabState();
}

class _ActivityTabState extends State<ActivityTab> {
  _Filter _filter = _Filter.all;

  void _openChat(BuildContext context, Chat chat) {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => ChatScreen(chat: chat)));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(
          [ChatStore.instance, CallLog.instance, FeedStore.instance]),
      builder: (context, _) {
        final unread = ChatStore.instance.chats
            .where((c) => c.unreadCount > 0)
            .toList()
          ..sort((a, b) {
            final at =
                a.messages.isEmpty ? DateTime(2000) : a.messages.last.time;
            final bt =
                b.messages.isEmpty ? DateTime(2000) : b.messages.last.time;
            return bt.compareTo(at);
          });
        final missed =
            CallLog.instance.records.where((r) => r.isMissed).take(10).toList();
        final posts = FeedStore.instance.recentPosts(limit: 5);

        final showMessages =
            _filter == _Filter.all || _filter == _Filter.messages;
        final showCalls = _filter == _Filter.all || _filter == _Filter.calls;
        final showServers =
            _filter == _Filter.all || _filter == _Filter.servers;

        final somethingVisible = (showMessages && unread.isNotEmpty) ||
            (showCalls && missed.isNotEmpty) ||
            (showServers && posts.isNotEmpty);

        return Column(
          children: [
            // Filter chips + mark-all-read on one compact row.
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 4, 0),
              child: Row(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final (f, label) in const [
                            (_Filter.all, 'All'),
                            (_Filter.messages, 'Messages'),
                            (_Filter.calls, 'Calls'),
                            (_Filter.servers, 'Servers'),
                          ])
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: ChoiceChip(
                                label: Text(label),
                                selected: _filter == f,
                                showCheckmark: false,
                                visualDensity: VisualDensity.compact,
                                onSelected: (_) =>
                                    setState(() => _filter = f),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (unread.isNotEmpty)
                    TextButton(
                      onPressed: () {
                        for (final c in unread) {
                          ChatStore.instance.markRead(c.id);
                        }
                      },
                      child: const Text('Mark all read'),
                    ),
                ],
              ),
            ),
            Expanded(
              child: !somethingVisible
                  ? PullToRefresh.emptyState(child: _empty(context))
                  : PullToRefresh(
                    child: ListView(
                        padding: const EdgeInsets.only(bottom: 96),
                        children: [
                          if (showMessages && unread.isNotEmpty) ...[
                            _sectionLabel(context, 'NEW MESSAGES'),
                            for (final chat in unread)
                              Dismissible(
                                key: ValueKey('unread_${chat.id}'),
                                direction: DismissDirection.endToStart,
                                background: _dismissBg(),
                                // Swiping away = mark read (the chat stays).
                                onDismissed: (_) =>
                                    ChatStore.instance.markRead(chat.id),
                                child: ListTile(
                                  leading:
                                      UserAvatar(user: chat.contact, radius: 22),
                                  title: Text(chat.contact.name,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w600)),
                                  subtitle: Text(
                                    chat.messages.isEmpty
                                        ? 'New messages'
                                        : chat.messages.last.text.isEmpty
                                            ? 'New message'
                                            : chat.messages.last.text,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  trailing: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 3),
                                    decoration: BoxDecoration(
                                      color:
                                          Theme.of(context).colorScheme.primary,
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Text(
                                      '${chat.unreadCount}',
                                      style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w700),
                                    ),
                                  ),
                                  onTap: () => _openChat(context, chat),
                                ),
                              ),
                          ],
                          if (showCalls && missed.isNotEmpty) ...[
                            _sectionLabel(context, 'MISSED CALLS'),
                            for (final r in missed)
                              ListTile(
                                leading: UserAvatar(user: r.user, radius: 22),
                                title: Text(r.user.name,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w600)),
                                subtitle: Text('Missed ${r.type.name} call · '
                                    '${DateFormatter.callLabel(r.time)}'),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.call_missed,
                                        color: Colors.red),
                                    IconButton(
                                      icon: const Icon(Icons.call),
                                      tooltip: 'Call back',
                                      onPressed: () => CallService.instance
                                          .startOutgoing(r.user, video: false),
                                    ),
                                  ],
                                ),
                                onTap: () {
                                  final chat = ChatStore.instance
                                      .chatWithContact(r.user.id);
                                  if (chat != null) _openChat(context, chat);
                                },
                              ),
                          ],
                          if (showServers && posts.isNotEmpty) ...[
                            _sectionLabel(context, 'NEW IN YOUR SERVERS'),
                            for (final p in posts)
                              ListTile(
                                leading: CircleAvatar(
                                  radius: 22,
                                  child: Text(p.authorName.isEmpty
                                      ? '?'
                                      : p.authorName[0].toUpperCase()),
                                ),
                                title: Text(p.authorName,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w600)),
                                subtitle: Text(p.text,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis),
                                trailing: Text(DateFormatter.callLabel(p.time),
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey.shade500)),
                                onTap: () => Navigator.of(context).push(
                                  MaterialPageRoute(
                                      builder: (_) =>
                                          FeedPostScreen(postId: p.id)),
                                ),
                              ),
                          ],
                        ],
                      ),
                  ),
            ),
          ],
        );
      },
    );
  }

  Widget _empty(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.notifications_none,
              size: 56, color: Colors.grey.shade400),
          const SizedBox(height: 12),
          Text("You're all caught up",
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: 4),
          Text('New messages, missed calls and server posts land here.',
              style: TextStyle(fontSize: 13.5, color: Colors.grey.shade500)),
        ],
      ),
    );
  }

  Widget _dismissBg() => Container(
        color: Colors.green,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: const Icon(Icons.mark_chat_read, color: Colors.white),
      );

  Widget _sectionLabel(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
        child: Text(text,
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: Colors.grey)),
      );
}
