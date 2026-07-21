import 'package:flutter/material.dart';

import '../models/message.dart';
import '../theme/app_theme.dart';
import '../utils/date_formatter.dart';
import 'message_status_icon.dart';

/// A single chat bubble, aligned left for incoming and right for outgoing.
class MessageBubble extends StatelessWidget {
  final Message message;
  final VoidCallback? onLongPress;

  const MessageBubble({super.key, required this.message, this.onLongPress});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isMe = message.isMe;

    final bubbleColor = isMe
        ? (isDark
            ? AppColors.outgoingBubbleDark
            : AppColors.outgoingBubbleLight)
        : (isDark
            ? AppColors.incomingBubbleDark
            : AppColors.incomingBubbleLight);

    final textColor = isDark ? Colors.white : Colors.black87;
    final metaColor = isDark ? Colors.white60 : Colors.black45;

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: onLongPress,
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.78,
          ),
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
          decoration: BoxDecoration(
            color: bubbleColor,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(8),
              topRight: const Radius.circular(8),
              bottomLeft: Radius.circular(isMe ? 8 : 0),
              bottomRight: Radius.circular(isMe ? 0 : 8),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 1,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                message.text,
                style: TextStyle(color: textColor, fontSize: 15.5, height: 1.3),
              ),
              const SizedBox(height: 2),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    DateFormatter.messageTime(message.time),
                    style: TextStyle(color: metaColor, fontSize: 11),
                  ),
                  if (isMe) ...[
                    const SizedBox(width: 4),
                    MessageStatusIcon(status: message.status, size: 15),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
