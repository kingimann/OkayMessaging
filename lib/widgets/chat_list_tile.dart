import 'package:flutter/material.dart';

import '../models/chat.dart';
import '../models/message.dart';
import '../theme/app_theme.dart';
import '../utils/date_formatter.dart';
import 'message_status_icon.dart';
import 'user_avatar.dart';

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
    final last = chat.lastMessage;
    final hasUnread = chat.unreadCount > 0;
    final subtitleColor =
        Theme.of(context).textTheme.bodySmall?.color ?? Colors.grey;

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            UserAvatar(user: chat.contact, radius: 28, showPresence: true),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          chat.contact.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 16.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        last == null
                            ? ''
                            : DateFormatter.chatListLabel(last.time),
                        style: TextStyle(
                          fontSize: 12,
                          color:
                              hasUnread ? AppColors.lightGreen : subtitleColor,
                          fontWeight:
                              hasUnread ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      if (last != null && last.isMe) ...[
                        MessageStatusIcon(status: last.status, size: 16),
                        const SizedBox(width: 3),
                      ],
                      if (last != null && last.isVoice) ...[
                        Icon(Icons.mic, size: 16, color: subtitleColor),
                        const SizedBox(width: 3),
                      ],
                      if (last != null && last.isImage) ...[
                        Icon(Icons.photo, size: 16, color: subtitleColor),
                        const SizedBox(width: 3),
                      ],
                      Expanded(
                        child: Text(
                          last != null && last.isVoice
                              ? 'Voice message'
                              : last != null && last.isImage
                                  ? 'Photo'
                                  : chat.preview,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            // Unread rows show a slightly darker, medium-weight
                            // preview so they stand out at a glance.
                            color: hasUnread
                                ? Theme.of(context).textTheme.bodyLarge?.color
                                : subtitleColor,
                            fontWeight:
                                hasUnread ? FontWeight.w500 : FontWeight.normal,
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
                          decoration: const BoxDecoration(
                            color: AppColors.lightGreen,
                            shape: BoxShape.circle,
                          ),
                          constraints: const BoxConstraints(
                            minWidth: 22,
                            minHeight: 22,
                          ),
                          child: Text(
                            '${chat.unreadCount}',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
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
