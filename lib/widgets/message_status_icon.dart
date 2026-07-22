import 'package:flutter/material.dart';

import '../models/message.dart';

/// The check-mark ticks shown next to outgoing messages. Colors are supplied
/// so the ticks contrast with whatever bubble they sit on.
class MessageStatusIcon extends StatelessWidget {
  final MessageStatus status;
  final double size;

  /// Color for sending/sent/delivered ticks (defaults to grey).
  final Color? color;

  /// Color for the "read" ticks (defaults to [color]).
  final Color? readColor;

  const MessageStatusIcon({
    super.key,
    required this.status,
    this.size = 16,
    this.color,
    this.readColor,
  });

  @override
  Widget build(BuildContext context) {
    final base = color ?? Colors.grey;
    switch (status) {
      case MessageStatus.sending:
        return Icon(Icons.access_time, size: size, color: base);
      case MessageStatus.sent:
        return Icon(Icons.done, size: size, color: base);
      case MessageStatus.delivered:
        return Icon(Icons.done_all, size: size, color: base);
      case MessageStatus.read:
        return Icon(Icons.done_all, size: size, color: readColor ?? base);
    }
  }
}
