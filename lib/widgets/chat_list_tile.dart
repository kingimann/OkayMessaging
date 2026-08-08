import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../state/chat_lock.dart';

import '../models/chat.dart';
import '../models/message.dart';
import '../state/chat_store.dart';
import '../relay/relay_service.dart';
import '../state/streak_store.dart';
import '../utils/date_formatter.dart';
import 'message_status_icon.dart';
import 'streak_chip.dart';
import 'user_avatar.dart';
import 'verified_badge.dart';

/// A single row in the chats list.
class ChatListTile extends StatelessWidget {
  final Chat chat;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const ChatListTile({
    super.key,
    required this.chat,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    // A locked chat's row stays — hiding it is what "hidden" is for, and this
    // one only has a password on it. What goes is the content: a preview is
    // the message, and a lock that shows the message it is locking protects
    // nothing. Same for "typing…", which says who is talking to whom.
    if (ChatLock.instance.isConcealed(chat.id)) return const SizedBox.shrink();
    if (!ChatLock.instance.isOpen(chat.id)) return _locked(context);
    return _open(context);
  }

  /// The row for a chat whose password has not been entered this session.
  Widget _locked(BuildContext context) => ListTile(
        onTap: onTap,
        onLongPress: onLongPress,
        leading: CircleAvatar(
          radius: 26,
          backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Icon(Icons.lock_outline,
              color: AppColors.subtle(context), size: 22),
        ),
        title: Text(chat.contact.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        subtitle: Text('Locked',
            style:
                TextStyle(fontSize: 14.5, color: AppColors.subtle(context))),
        // No unread badge either: a count is how many things somebody has to
        // say to you, which is not nothing.
      );

  Widget _open(BuildContext context) {
    final last = chat.lastMessage;
    final draft = ChatStore.instance.draftFor(chat.id);
    final hasUnread = chat.unreadCount > 0;
    final subtitleColor =
        Theme.of(context).textTheme.bodySmall?.color ?? Colors.grey;

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        child: Row(
          children: [
            UserAvatar(user: chat.contact, radius: 28, showPresence: true),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: NameWithBadge(
                          name: chat.contact.name,
                          verified: chat.contact.verified,
                          business: chat.contact.isBusiness,
                          badgeSize: 16,
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                          ),
                          trailing: () {
                            final streak =
                                StreakStore.instance.streakFor(chat.id);
                            return streak > 0
                                ? StreakChip(
                                    count: streak,
                                    expiring: StreakStore.instance
                                        .isExpiringSoon(chat.id),
                                  )
                                : null;
                          }(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        last == null
                            ? ''
                            : DateFormatter.chatListLabel(last.time),
                        // Unread is emphasis, so it takes the accent — which
                        // in this palette is near-black in light and
                        // near-white in dark. It used to take a fixed grey
                        // (#536471) that is 3.2:1 on the dark background, so
                        // the row asking to be read was the dimmest one on
                        // the screen.
                        style: TextStyle(
                          fontSize: 12,
                          color: hasUnread
                              ? Theme.of(context).colorScheme.primary
                              : subtitleColor,
                          fontWeight:
                              hasUnread ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Row(
                    children: [
                      if (draft.isEmpty && last != null && last.isMe) ...[
                        MessageStatusIcon(status: last.status, size: 16),
                        const SizedBox(width: 3),
                      ],
                      if (draft.isEmpty && last != null && last.isVoice) ...[
                        Icon(Icons.mic, size: 16, color: subtitleColor),
                        const SizedBox(width: 3),
                      ],
                      if (draft.isEmpty && last != null && last.isImage) ...[
                        Icon(Icons.photo, size: 16, color: subtitleColor),
                        const SizedBox(width: 3),
                      ],
                      Expanded(
                        child: ValueListenableBuilder<int>(
                          valueListenable: RelayService.instance.typingPing,
                          builder: (context, _, child) {
                            // Live "typing…" straight from the relay ping,
                            // scoped: a group ping lights the group tile, a 1:1
                            // ping lights the 1:1 tile — never each other.
                            final relay = RelayService.instance;
                            final digits =
                                RelayService.digits(chat.contact.phone);
                            final isTyping = chat.contact.isGroup
                                ? relay.typingGroupId == chat.id
                                : (relay.typingGroupId.isEmpty &&
                                    digits.isNotEmpty &&
                                    relay.typingFromDigits == digits);
                            if (isTyping) {
                              return Text(
                                'typing…',
                                style: TextStyle(
                                  fontSize: 14.5,
                                  color: Theme.of(context).colorScheme.primary,
                                  fontWeight: FontWeight.w600,
                                ),
                              );
                            }
                            return child!;
                          },
                          child: draft.isNotEmpty
                              ? _DraftPreview(
                                  draft: draft, subtitleColor: subtitleColor)
                              : Text(
                                  chat.preview,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 14.5,
                                    color: hasUnread
                                        ? Theme.of(context)
                                            .textTheme
                                            .bodyLarge
                                            ?.color
                                        : subtitleColor,
                                    fontWeight: hasUnread
                                        ? FontWeight.w500
                                        : FontWeight.normal,
                                  ),
                                ),
                        ),
                      ),
                      if (chat.isMuted)
                        const Padding(
                          padding: EdgeInsets.only(left: 4),
                          child: Icon(Icons.volume_off,
                              size: 16, color: Colors.grey),
                        ),
                      if (chat.isPinned && !hasUnread)
                        const Padding(
                          padding: EdgeInsets.only(left: 4),
                          child: Icon(Icons.push_pin,
                              size: 15, color: Colors.grey),
                        ),
                      if (hasUnread) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primary,
                            shape: BoxShape.circle,
                          ),
                          constraints: const BoxConstraints(
                            minWidth: 22,
                            minHeight: 22,
                          ),
                          child: Text(
                            '${chat.unreadCount}',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onPrimary,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Small helper to expose the last message type where needed.
extension ChatLastMessage on Chat {
  Message? get latest => messages.isEmpty ? null : messages.last;
}

/// The red "Draft:" prefix plus the saved draft text.
class _DraftPreview extends StatelessWidget {
  final String draft;
  final Color subtitleColor;
  const _DraftPreview({required this.draft, required this.subtitleColor});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Text(
          'Draft: ',
          style: TextStyle(
            fontSize: 14.5,
            color: Color(0xFFEB4B3F),
            fontWeight: FontWeight.w500,
          ),
        ),
        Expanded(
          child: Text(
            draft,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 14.5, color: subtitleColor),
          ),
        ),
      ],
    );
  }
}
