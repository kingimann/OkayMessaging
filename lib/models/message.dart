/// Delivery state of an outgoing message, mirroring WhatsApp's tick system.
enum MessageStatus { sending, sent, delivered, read }

/// A single chat message.
class Message {
  final String id;
  final String text;
  final DateTime time;

  /// True when the message was sent by the current (local) user.
  final bool isMe;
  final MessageStatus status;

  const Message({
    required this.id,
    required this.text,
    required this.time,
    required this.isMe,
    this.status = MessageStatus.read,
  });
}
