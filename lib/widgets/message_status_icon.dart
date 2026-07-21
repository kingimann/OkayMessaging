import 'package:flutter/material.dart';

import '../models/message.dart';
import '../theme/app_theme.dart';

/// The check-mark ticks shown next to outgoing messages.
class MessageStatusIcon extends StatelessWidget {
  final MessageStatus status;
  final double size;

  const MessageStatusIcon({super.key, required this.status, this.size = 16});

  @override
  Widget build(BuildContext context) {
    switch (status) {
      case MessageStatus.sending:
        return Icon(Icons.access_time, size: size, color: Colors.grey);
      case MessageStatus.sent:
        return Icon(Icons.done, size: size, color: Colors.grey);
      case MessageStatus.delivered:
        return Icon(Icons.done_all, size: size, color: Colors.grey);
      case MessageStatus.read:
        return Icon(Icons.done_all, size: size, color: AppColors.readTick);
    }
  }
}
