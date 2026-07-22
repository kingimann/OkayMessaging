/// Delivery state of an outgoing message, mirroring WhatsApp's tick system.
enum MessageStatus { sending, sent, delivered, read }

/// Lightweight reference to the message being replied to (quoted).
class ReplyInfo {
  final String senderName;
  final String text;
  final bool isMe;

  /// Id of the original message, so tapping the quote can jump to it.
  final String? messageId;

  const ReplyInfo({
    required this.senderName,
    required this.text,
    required this.isMe,
    this.messageId,
  });

  Map<String, dynamic> toJson() => {
        'senderName': senderName,
        'text': text,
        'isMe': isMe,
        'messageId': messageId,
      };

  factory ReplyInfo.fromJson(Map<String, dynamic> json) => ReplyInfo(
        senderName: json['senderName'] as String,
        text: json['text'] as String,
        isMe: json['isMe'] as bool,
        messageId: json['messageId'] as String?,
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

  /// True when this voice message is a voicemail left after an unanswered
  /// call (a [isVoice] message surfaced separately in the Calls tab).
  final bool isVoicemail;

  /// True when this message has been edited after sending.
  final bool edited;

  /// True for image messages; [imageSeed] picks a placeholder gradient when
  /// there is no real [imageUrl] (e.g. in the local demo).
  final bool isImage;
  final int imageSeed;

  /// A real image URL (from backend storage), when available.
  final String? imageUrl;

  /// When set, the message is deleted from the device after this time
  /// (disappearing messages).
  final DateTime? expiresAt;

  /// True for a shared-location message; [locationLat]/[locationLng] hold the
  /// coordinates and [locationLabel] an optional place name.
  final bool isLocation;
  final double? locationLat;
  final double? locationLng;
  final String? locationLabel;

  /// True for a shared-contact card; [contactName]/[contactPhone] hold the
  /// shared person's details.
  final bool isContact;
  final String? contactName;
  final String? contactPhone;

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
    this.isVoicemail = false,
    this.isImage = false,
    this.imageSeed = 0,
    this.imageUrl,
    this.edited = false,
    this.expiresAt,
    this.isLocation = false,
    this.locationLat,
    this.locationLng,
    this.locationLabel,
    this.isContact = false,
    this.contactName,
    this.contactPhone,
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
        'isVoicemail': isVoicemail,
        'isImage': isImage,
        'imageSeed': imageSeed,
        'imageUrl': imageUrl,
        'edited': edited,
        'expiresAt': expiresAt?.toIso8601String(),
        'isLocation': isLocation,
        'locationLat': locationLat,
        'locationLng': locationLng,
        'locationLabel': locationLabel,
        'isContact': isContact,
        'contactName': contactName,
        'contactPhone': contactPhone,
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
        isVoicemail: json['isVoicemail'] as bool? ?? false,
        isImage: json['isImage'] as bool? ?? false,
        imageSeed: json['imageSeed'] as int? ?? 0,
        imageUrl: json['imageUrl'] as String?,
        edited: json['edited'] as bool? ?? false,
        expiresAt: json['expiresAt'] == null
            ? null
            : DateTime.tryParse(json['expiresAt'] as String),
        isLocation: json['isLocation'] as bool? ?? false,
        locationLat: (json['locationLat'] as num?)?.toDouble(),
        locationLng: (json['locationLng'] as num?)?.toDouble(),
        locationLabel: json['locationLabel'] as String?,
        isContact: json['isContact'] as bool? ?? false,
        contactName: json['contactName'] as String?,
        contactPhone: json['contactPhone'] as String?,
      );

  Message copyWith({
    String? text,
    MessageStatus? status,
    List<String>? reactions,
    bool? edited,
    DateTime? expiresAt,
  }) {
    return Message(
      id: id,
      text: text ?? this.text,
      time: time,
      isMe: isMe,
      status: status ?? this.status,
      reactions: reactions ?? this.reactions,
      replyTo: replyTo,
      forwarded: forwarded,
      isVoice: isVoice,
      voiceSeconds: voiceSeconds,
      isVoicemail: isVoicemail,
      isImage: isImage,
      imageSeed: imageSeed,
      imageUrl: imageUrl,
      edited: edited ?? this.edited,
      expiresAt: expiresAt ?? this.expiresAt,
      isLocation: isLocation,
      locationLat: locationLat,
      locationLng: locationLng,
      locationLabel: locationLabel,
      isContact: isContact,
      contactName: contactName,
      contactPhone: contactPhone,
    );
  }
}
