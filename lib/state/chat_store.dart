import 'package:flutter/foundation.dart';

import '../data/mock_data.dart';
import '../models/chat.dart';
import '../models/message.dart';

/// Single in-memory source of truth for conversations, so pin/mute/archive,
/// unread counts, sent messages, and reactions stay consistent across every
/// screen. Kept deliberately simple (a [ChangeNotifier]) for this demo.
class ChatStore extends ChangeNotifier {
  ChatStore._() {
    _chats = MockData.chats();
  }

  static final ChatStore instance = ChatStore._();

  late List<Chat> _chats;

  /// Ids of messages the user has starred.
  final Set<String> _starred = {};

  /// Invoked after every change so a persistence layer can save.
  void Function()? onChanged;

  @override
  void notifyListeners() {
    super.notifyListeners();
    onChanged?.call();
  }

  Map<String, dynamic> toJson() => {
        'chats': _chats.map((c) => c.toJson()).toList(),
        'starred': _starred.toList(),
      };

  /// Replaces all state from a previously-saved [json] snapshot.
  void hydrate(Map<String, dynamic> json) {
    _chats = (json['chats'] as List)
        .map((c) => Chat.fromJson(Map<String, dynamic>.from(c as Map)))
        .toList();
    _starred
      ..clear()
      ..addAll((json['starred'] as List? ?? const []).map((e) => '$e'));
    notifyListeners();
  }

  /// Reloads the initial sample data. Intended for tests to isolate state
  /// between cases (the store is otherwise a long-lived singleton).
  @visibleForTesting
  void reset() {
    _chats = MockData.chats();
    _starred.clear();
    notifyListeners();
  }

  int _indexOf(String id) => _chats.indexWhere((c) => c.id == id);

  Chat? chatById(String id) {
    final i = _indexOf(id);
    return i == -1 ? null : _chats[i];
  }

  List<Chat> _sorted(Iterable<Chat> chats) {
    final list = chats.toList();
    list.sort((a, b) {
      if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
      final at = a.lastMessage?.time ?? DateTime(0);
      final bt = b.lastMessage?.time ?? DateTime(0);
      return bt.compareTo(at);
    });
    return list;
  }

  /// Visible (non-archived) conversations, pinned first then most-recent.
  List<Chat> get chats => _sorted(_chats.where((c) => !c.isArchived));

  List<Chat> get archivedChats => _sorted(_chats.where((c) => c.isArchived));

  int get archivedCount => _chats.where((c) => c.isArchived).length;

  /// Every conversation regardless of archived state (used by search).
  List<Chat> get allChats => List.unmodifiable(_chats);

  /// The existing conversation with [contactId], if one exists.
  Chat? chatWithContact(String contactId) {
    final i = _chats.indexWhere((c) => c.contact.id == contactId);
    return i == -1 ? null : _chats[i];
  }

  void _replace(int index, Chat chat) {
    _chats[index] = chat;
    notifyListeners();
  }

  void togglePin(String id) {
    final i = _indexOf(id);
    if (i != -1) _replace(i, _chats[i].copyWith(isPinned: !_chats[i].isPinned));
  }

  void toggleMute(String id) {
    final i = _indexOf(id);
    if (i != -1) _replace(i, _chats[i].copyWith(isMuted: !_chats[i].isMuted));
  }

  void setArchived(String id, bool archived) {
    final i = _indexOf(id);
    if (i != -1) {
      // Un-pin when archiving so it doesn't jump to the top on restore.
      _replace(
        i,
        _chats[i].copyWith(
          isArchived: archived,
          isPinned: archived ? false : _chats[i].isPinned,
        ),
      );
    }
  }

  void markRead(String id) {
    final i = _indexOf(id);
    if (i != -1 && _chats[i].unreadCount != 0) {
      _replace(i, _chats[i].copyWith(unreadCount: 0));
    }
  }

  void markUnread(String id) {
    final i = _indexOf(id);
    if (i != -1 && _chats[i].unreadCount == 0) {
      _replace(i, _chats[i].copyWith(unreadCount: 1));
    }
  }

  void deleteChat(String id) {
    final i = _indexOf(id);
    if (i != -1) {
      _chats.removeAt(i);
      notifyListeners();
    }
  }

  /// Ensures a conversation exists for [chat] (used when starting a new chat).
  void upsert(Chat chat) {
    final i = _indexOf(chat.id);
    if (i == -1) {
      _chats.add(chat);
      notifyListeners();
    }
  }

  void addMessage(String chatId, Message message) {
    final i = _indexOf(chatId);
    if (i == -1) return;
    _replace(
      i,
      _chats[i].copyWith(messages: [..._chats[i].messages, message]),
    );
  }

  void replaceMessages(String chatId, List<Message> messages) {
    final i = _indexOf(chatId);
    if (i == -1) return;
    _replace(i, _chats[i].copyWith(messages: messages));
  }

  void deleteMessage(String chatId, String messageId) {
    final i = _indexOf(chatId);
    if (i == -1) return;
    final msgs = _chats[i].messages.where((m) => m.id != messageId).toList();
    _replace(i, _chats[i].copyWith(messages: msgs));
  }

  // Message ids are only unique within a chat, so star keys are composite.
  String _starKey(String chatId, String messageId) => '$chatId::$messageId';

  bool isStarred(String chatId, String messageId) =>
      _starred.contains(_starKey(chatId, messageId));

  void toggleStar(String chatId, String messageId) {
    final key = _starKey(chatId, messageId);
    if (!_starred.remove(key)) _starred.add(key);
    notifyListeners();
  }

  /// All starred messages paired with the conversation they belong to.
  List<({Chat chat, Message message})> starredMessages() {
    final out = <({Chat chat, Message message})>[];
    for (final c in _chats) {
      for (final m in c.messages) {
        if (_starred.contains(_starKey(c.id, m.id))) {
          out.add((chat: c, message: m));
        }
      }
    }
    out.sort((a, b) => b.message.time.compareTo(a.message.time));
    return out;
  }

  /// Toggles [emoji] on a message: adds it if absent, removes it if present.
  void toggleReaction(String chatId, String messageId, String emoji) {
    final i = _indexOf(chatId);
    if (i == -1) return;
    final msgs = _chats[i].messages.map((m) {
      if (m.id != messageId) return m;
      final reactions = List<String>.from(m.reactions);
      if (reactions.contains(emoji)) {
        reactions.remove(emoji);
      } else {
        reactions.add(emoji);
      }
      return m.copyWith(reactions: reactions);
    }).toList();
    _replace(i, _chats[i].copyWith(messages: msgs));
  }
}
