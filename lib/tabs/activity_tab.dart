import 'package:flutter/material.dart';

import '../models/chat.dart';
import '../state/call_log.dart';
import '../state/call_service.dart';
import '../state/chat_store.dart';
import '../screens/chat_screen.dart';
import '../utils/date_formatter.dart';
import '../widgets/user_avatar.dart';

/// The Notifications tab: everything that happened while you were away —
/// unread messages and missed calls — built purely from real local state
/// (no invented activity).
class ActivityTab extends StatelessWidget {
  const ActivityTab({super.key});

  void _openChat(BuildContext context, Chat chat) {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => ChatScreen(chat: chat)));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([ChatStore.instance, CallLog.instance]),
      builder: (context, _) {
        final unread = ChatStore.instance.chats
            .where((c) => c.unreadCount > 0)
            .toList()
          ..sort((a, b) {
            final at = a.messages.isEmpty ? DateTime(2000) : a.messages.last.time;
            final bt = b.messages.isEmpty ? DateTime(2000) : b.messages.last.time;
            return bt.compareTo(at);
          });
        final missed = CallLog.instance.records
            .where((r) => r.isMissed)
            .take(10)
            .toList();

        if (unread.isEmpty && missed.isEmpty) {
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
                        color: Colors.grey.shade600)),
                const SizedBox(height: 4),
                Text('New messages and missed calls land here.',
                    style: TextStyle(
                        fontSize: 13.5, color: Colors.grey.shade500)),
              ],
            ),
          );
        }

        return ListView(
          padding: const EdgeInsets.only(bottom: 96),
          children: [
            if (unread.isNotEmpty) ...[
              _sectionLabel(context, 'NEW MESSAGES'),
              for (final chat in unread)
                ListTile(
                  leading: UserAvatar(user: chat.contact, radius: 22),
                  title: Text(chat.contact.name,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
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
                      color: Theme.of(context).colorScheme.primary,
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
            ],
            if (missed.isNotEmpty) ...[
              _sectionLabel(context, 'MISSED CALLS'),
              for (final r in missed)
                ListTile(
                  leading: UserAvatar(user: r.user, radius: 22),
                  title: Text(r.user.name,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text('Missed ${r.type.name} call · '
                      '${DateFormatter.callLabel(r.time)}'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.call_missed, color: Colors.red),
                      IconButton(
                        icon: const Icon(Icons.call),
                        tooltip: 'Call back',
                        onPressed: () => CallService.instance
                            .startOutgoing(r.user, video: false),
                      ),
                    ],
                  ),
                  onTap: () {
                    final chat =
                        ChatStore.instance.chatWithContact(r.user.id);
                    if (chat != null) _openChat(context, chat);
                  },
                ),
            ],
          ],
        );
      },
    );
  }

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
