import 'package:flutter/material.dart';

import '../models/message.dart';

/// The check-mark ticks shown next to outgoing messages, WhatsApp/X-style:
/// a clock while sending, one tick sent, two grey ticks delivered, and two
/// BLUE ticks once read — the read colour is the whole signal, so it's a
/// distinct accent rather than a slightly brighter grey.
class MessageStatusIcon extends StatelessWidget {
  final MessageStatus status;
  final double size;

  /// Color for sending/sent/delivered ticks (defaults to grey).
  final Color? color;

  /// Color for the "read" ticks. Defaults to a distinct blue ([readBlue]) that
  /// reads on both light and dark outgoing bubbles — NOT [color], so delivered
  /// and read never look the same.
  final Color? readColor;

  /// The "seen" blue, the same hue WhatsApp/Messenger use for read receipts.
  static const Color readBlue = Color(0xFF34B7F1);

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
        return Icon(Icons.done_all, size: size, color: readColor ?? readBlue);
    }
  }
}
