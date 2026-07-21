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

  Map<String, dynamic> toJson() =>
      {'senderName': senderName, 'text': text, 'isMe': isMe};

  factory ReplyInfo.fromJson(Map<String, dynamic> json) => ReplyInfo(
        senderName: json['senderName'] as String,
        text: json['text'] as String,
        isMe: json['isMe'] as bool,
      );
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

  /// True when this message was forwarded from another chat.
  final bool forwarded;

  /// True for voice messages; [voiceSeconds] then holds the clip length.
  final bool isVoice;
  final int voiceSeconds;

  const Message({
    required this.id,
    required this.text,
    required this.time,
    required this.isMe,
    this.status = MessageStatus.read,
    this.reactions = const [],
    this.replyTo,
    this.forwarded = false,
    this.isVoice = false,
    this.voiceSeconds = 0,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'time': time.toIso8601String(),
        'isMe': isMe,
        'status': status.index,
        'reactions': reactions,
        'replyTo': replyTo?.toJson(),
        'forwarded': forwarded,
        'isVoice': isVoice,
        'voiceSeconds': voiceSeconds,
      };

  factory Message.fromJson(Map<String, dynamic> json) => Message(
        id: json['id'] as String,
        text: json['text'] as String,
        time: DateTime.parse(json['time'] as String),
        isMe: json['isMe'] as bool,
        status: MessageStatus.values[json['status'] as int? ?? 3],
        reactions: (json['reactions'] as List?)?.cast<String>() ?? const [],
        replyTo: json['replyTo'] == null
            ? null
            : ReplyInfo.fromJson(
                Map<String, dynamic>.from(json['replyTo'] as Map)),
        forwarded: json['forwarded'] as bool? ?? false,
        isVoice: json['isVoice'] as bool? ?? false,
        voiceSeconds: json['voiceSeconds'] as int? ?? 0,
      );

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
      forwarded: forwarded,
      isVoice: isVoice,
      voiceSeconds: voiceSeconds,
    );
  }
}
