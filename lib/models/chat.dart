import 'message.dart';
import 'user.dart';

/// A conversation between the current user and another [AppUser].
class Chat {
  final String id;
  final AppUser contact;
  final List<Message> messages;
  final int unreadCount;
  final bool isPinned;
  final bool isMuted;
  final bool isArchived;
  final bool isFavorite;

  /// The id of the message pinned to the top of this chat, if any.
  final String? pinnedMessageId;

  /// Participants of a group chat (empty for 1:1 conversations).
  final List<AppUser> members;

  /// Disappearing-messages timer in seconds; 0 means off. New messages in this
  /// chat are deleted from the device this long after they're sent.
  final int disappearingSeconds;

  const Chat({
    required this.id,
    required this.contact,
    required this.messages,
    this.unreadCount = 0,
    this.isPinned = false,
    this.isMuted = false,
    this.isArchived = false,
    this.isFavorite = false,
    this.pinnedMessageId,
    this.members = const [],
    this.disappearingSeconds = 0,
  });

  /// Most recent message, or null when the conversation is empty.
  Message? get lastMessage => messages.isEmpty ? null : messages.last;

  /// Preview text shown in the chat list.
  String get preview {
    final m = lastMessage;
    if (m == null) return '';
    if (m.isImage) return 'Photo';
    if (m.isVoice) return 'Voice message';
    if (m.isLocation) return 'Location';
    if (m.isContact) return 'Contact: ${m.contactName ?? ''}';
    return m.text;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'contact': contact.toJson(),
        'messages': messages.map((m) => m.toJson()).toList(),
        'unreadCount': unreadCount,
        'isPinned': isPinned,
        'isMuted': isMuted,
        'isArchived': isArchived,
        'isFavorite': isFavorite,
        'pinnedMessageId': pinnedMessageId,
        'members': members.map((m) => m.toJson()).toList(),
        'disappearingSeconds': disappearingSeconds,
      };

  factory Chat.fromJson(Map<String, dynamic> json) => Chat(
        id: json['id'] as String,
        contact:
            AppUser.fromJson(Map<String, dynamic>.from(json['contact'] as Map)),
        messages: (json['messages'] as List)
            .map((m) => Message.fromJson(Map<String, dynamic>.from(m as Map)))
            .toList(),
        unreadCount: json['unreadCount'] as int? ?? 0,
        isPinned: json['isPinned'] as bool? ?? false,
        isMuted: json['isMuted'] as bool? ?? false,
        isArchived: json['isArchived'] as bool? ?? false,
        isFavorite: json['isFavorite'] as bool? ?? false,
        pinnedMessageId: json['pinnedMessageId'] as String?,
        members: (json['members'] as List? ?? const [])
            .map((m) => AppUser.fromJson(Map<String, dynamic>.from(m as Map)))
            .toList(),
        disappearingSeconds: json['disappearingSeconds'] as int? ?? 0,
      );

  Chat copyWith({
    AppUser? contact,
    List<Message>? messages,
    int? unreadCount,
    bool? isPinned,
    bool? isMuted,
    bool? isArchived,
    bool? isFavorite,
    String? pinnedMessageId,
    bool clearPinned = false,
    int? disappearingSeconds,
  }) {
    return Chat(
      id: id,
      contact: contact ?? this.contact,
      messages: messages ?? this.messages,
      unreadCount: unreadCount ?? this.unreadCount,
      isPinned: isPinned ?? this.isPinned,
      isMuted: isMuted ?? this.isMuted,
      isArchived: isArchived ?? this.isArchived,
      isFavorite: isFavorite ?? this.isFavorite,
      pinnedMessageId:
          clearPinned ? null : (pinnedMessageId ?? this.pinnedMessageId),
      members: members,
      disappearingSeconds: disappearingSeconds ?? this.disappearingSeconds,
    );
  }
}
