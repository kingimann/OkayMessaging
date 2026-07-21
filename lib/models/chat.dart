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

  /// The id of the message pinned to the top of this chat, if any.
  final String? pinnedMessageId;

  const Chat({
    required this.id,
    required this.contact,
    required this.messages,
    this.unreadCount = 0,
    this.isPinned = false,
    this.isMuted = false,
    this.isArchived = false,
    this.pinnedMessageId,
  });

  /// Most recent message, or null when the conversation is empty.
  Message? get lastMessage => messages.isEmpty ? null : messages.last;

  /// Preview text shown in the chat list.
  String get preview => lastMessage?.text ?? '';

  Map<String, dynamic> toJson() => {
        'id': id,
        'contact': contact.toJson(),
        'messages': messages.map((m) => m.toJson()).toList(),
        'unreadCount': unreadCount,
        'isPinned': isPinned,
        'isMuted': isMuted,
        'isArchived': isArchived,
        'pinnedMessageId': pinnedMessageId,
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
        pinnedMessageId: json['pinnedMessageId'] as String?,
      );

  Chat copyWith({
    List<Message>? messages,
    int? unreadCount,
    bool? isPinned,
    bool? isMuted,
    bool? isArchived,
    String? pinnedMessageId,
    bool clearPinned = false,
  }) {
    return Chat(
      id: id,
      contact: contact,
      messages: messages ?? this.messages,
      unreadCount: unreadCount ?? this.unreadCount,
      isPinned: isPinned ?? this.isPinned,
      isMuted: isMuted ?? this.isMuted,
      isArchived: isArchived ?? this.isArchived,
      pinnedMessageId:
          clearPinned ? null : (pinnedMessageId ?? this.pinnedMessageId),
    );
  }
}
