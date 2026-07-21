/// Delivery state of an outgoing message, mirroring WhatsApp's tick system.
enum MessageStatus { sending, sent, delivered, read }

/// Lightweight reference to the message being replied to (quoted).
class ReplyInfo {
  final String senderName;
  final String text;
  final bool isMe;

  const ReplyInfo({
    required this.senderName,
    required this.text,
    required this.isMe,
  });
}

/// A single chat message.
class Message {
  final String id;
  final String text;
  final DateTime time;

  /// True when the message was sent by the current (local) user.
  final bool isMe;
  final MessageStatus status;

  /// Emoji reactions attached to this message (e.g. ['👍', '❤️']).
  final List<String> reactions;

  /// The quoted message this one replies to, if any.
  final ReplyInfo? replyTo;

  const Message({
    required this.id,
    required this.text,
    required this.time,
    required this.isMe,
    this.status = MessageStatus.read,
    this.reactions = const [],
    this.replyTo,
  });

  Message copyWith({
    MessageStatus? status,
    List<String>? reactions,
  }) {
    return Message(
      id: id,
      text: text,
      time: time,
      isMe: isMe,
      status: status ?? this.status,
      reactions: reactions ?? this.reactions,
      replyTo: replyTo,
    );
  }
}
