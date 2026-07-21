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

  const Chat({
    required this.id,
    required this.contact,
    required this.messages,
    this.unreadCount = 0,
    this.isPinned = false,
    this.isMuted = false,
    this.isArchived = false,
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
      );

  Chat copyWith({
    List<Message>? messages,
    int? unreadCount,
    bool? isPinned,
    bool? isMuted,
    bool? isArchived,
  }) {
    return Chat(
      id: id,
      contact: contact,
      messages: messages ?? this.messages,
      unreadCount: unreadCount ?? this.unreadCount,
      isPinned: isPinned ?? this.isPinned,
      isMuted: isMuted ?? this.isMuted,
      isArchived: isArchived ?? this.isArchived,
    );
  }
}
