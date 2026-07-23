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

  /// Ids of messages pinned to the top of this chat, oldest first. Free
  /// accounts can pin a few; Okay Pro lifts the limit.
  final List<String> pinnedMessageIds;

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
    this.pinnedMessageIds = const [],
    this.members = const [],
    this.disappearingSeconds = 0,
  });

  /// Most recent message, or null when the conversation is empty.
  Message? get lastMessage => messages.isEmpty ? null : messages.last;

  /// The most recently pinned message id, or null when nothing is pinned.
  String? get pinnedMessageId =>
      pinnedMessageIds.isEmpty ? null : pinnedMessageIds.last;

  /// Whether [messageId] is currently pinned in this chat.
  bool isPinnedMessage(String messageId) =>
      pinnedMessageIds.contains(messageId);

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
        'pinnedMessageIds': pinnedMessageIds,
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
        pinnedMessageIds: _readPinned(json),
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
    List<String>? pinnedMessageIds,
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
      pinnedMessageIds:
          clearPinned ? const [] : (pinnedMessageIds ?? this.pinnedMessageIds),
      members: members,
      disappearingSeconds: disappearingSeconds ?? this.disappearingSeconds,
    );
  }

  /// Reads the pinned-message ids, migrating the legacy single-id field from
  /// chats saved before multi-pin support.
  static List<String> _readPinned(Map<String, dynamic> json) {
    final list = json['pinnedMessageIds'];
    if (list is List) {
      return list.map((e) => e.toString()).toList();
    }
    final legacy = json['pinnedMessageId'];
    return legacy is String ? [legacy] : const [];
  }
}
