import 'dart:async';
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';

import '../data/mock_data.dart';
import '../models/chat.dart';
import '../models/message.dart';
import '../models/user.dart';

/// Single in-memory source of truth for conversations, so pin/mute/archive,
/// unread counts, sent messages, and reactions stay consistent across every
/// screen. Kept deliberately simple (a [ChangeNotifier]) for this demo.
class ChatStore extends ChangeNotifier {
  ChatStore._() {
    _chats = MockData.chats();
  }

  static final ChatStore instance = ChatStore._();

  late List<Chat> _chats;

  Timer? _sweeper;

  /// Starts a periodic sweep that deletes expired (disappearing) messages even
  /// while their chat isn't open. Safe to call once at startup.
  void startSweeper() {
    _sweeper ??=
        Timer.periodic(const Duration(seconds: 20), (_) => sweepExpired());
  }

  /// Ids of messages the user has starred.
  final Set<String> _starred = {};

  /// Unsent composer text per chat id (drafts), restored when you reopen a
  /// conversation.
  final Map<String, String> _drafts = {};

  /// Per-chat wallpaper color (ARGB int) overriding the global default.
  final Map<String, int> _wallpapers = {};

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
        'drafts': Map<String, String>.of(_drafts),
        'wallpapers': Map<String, int>.of(_wallpapers),
      };

  /// Replaces all state from a previously-saved [json] snapshot.
  void hydrate(Map<String, dynamic> json) {
    _chats = (json['chats'] as List)
        .map((c) => Chat.fromJson(Map<String, dynamic>.from(c as Map)))
        .toList();
    _starred
      ..clear()
      ..addAll((json['starred'] as List? ?? const []).map((e) => '$e'));
    _drafts
      ..clear()
      ..addAll((json['drafts'] as Map? ?? const {})
          .map((k, v) => MapEntry('$k', '$v')));
    _wallpapers
      ..clear()
      ..addAll((json['wallpapers'] as Map? ?? const {})
          .map((k, v) => MapEntry('$k', v as int)));
    notifyListeners();
  }

  /// The wallpaper override for [chatId], or null to use the global default.
  Color? wallpaperFor(String chatId) {
    final v = _wallpapers[chatId];
    return v == null ? null : Color(v);
  }

  /// Sets (or clears, with null) a per-chat wallpaper.
  void setWallpaper(String chatId, Color? color) {
    if (color == null) {
      _wallpapers.remove(chatId);
    } else {
      _wallpapers[chatId] = color.toARGB32();
    }
    notifyListeners();
  }

  /// The saved draft for [chatId] (empty when none).
  String draftFor(String chatId) => _drafts[chatId] ?? '';

  /// Saves (or clears, when empty) the composer draft for [chatId]. Notifies
  /// listeners only when the draft appears/disappears (so the chat-list
  /// indicator updates), otherwise just persists — no per-keystroke rebuild.
  void setDraft(String chatId, String text) {
    final trimmed = text.trim();
    final current = _drafts[chatId] ?? '';
    if (trimmed == current) return;
    final visibilityChanged = trimmed.isEmpty != current.isEmpty;
    if (trimmed.isEmpty) {
      _drafts.remove(chatId);
    } else {
      _drafts[chatId] = trimmed;
    }
    if (visibilityChanged) {
      notifyListeners();
    } else {
      onChanged?.call();
    }
  }

  /// Replaces all conversations wholesale (used by the backend sync to push
  /// server state into the store). Preserves the local starred set.
  void setChats(List<Chat> chats) {
    _chats = List.of(chats);
    notifyListeners();
  }

  /// Deletes every conversation from the device. Used by Settings →
  /// "Storage and data" → clear all chats.
  void clearAll() {
    _chats = [];
    _starred.clear();
    _drafts.clear();
    _wallpapers.clear();
    notifyListeners();
  }

  /// Reloads the initial sample data. Intended for tests to isolate state
  /// between cases (the store is otherwise a long-lived singleton).
  @visibleForTesting
  void reset() {
    _chats = MockData.chats();
    _starred.clear();
    _drafts.clear();
    _wallpapers.clear();
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

  /// Refreshes the stored [avatarColor] and/or [about] of the contact whose
  /// phone id matches [contactId] — used when a peer shares updated profile
  /// info on an incoming message (subject to their privacy settings). No-ops
  /// when nothing changes, so it won't churn the list needlessly.
  void updateContactProfile(String contactId,
      {String? avatarColor, String? about}) {
    final i = _chats.indexWhere((c) => c.contact.id == contactId);
    if (i == -1) return;
    final c = _chats[i].contact;
    final nextColor =
        (avatarColor != null && avatarColor.isNotEmpty) ? avatarColor : c.avatarColor;
    final nextAbout =
        (about != null && about.isNotEmpty) ? about : c.about;
    if (nextColor == c.avatarColor && nextAbout == c.about) return;
    _replace(
      i,
      _chats[i].copyWith(
        contact: AppUser(
          id: c.id,
          name: c.name,
          avatarColor: nextColor,
          about: nextAbout,
          phone: c.phone,
          username: c.username,
          isOnline: c.isOnline,
          isGroup: c.isGroup,
        ),
      ),
    );
  }

  void addMessage(String chatId, Message message) {
    final i = _indexOf(chatId);
    if (i == -1) return;
    var msg = message;
    // Stamp an expiry when the chat has disappearing messages enabled.
    final ttl = _chats[i].disappearingSeconds;
    if (ttl > 0 && msg.expiresAt == null) {
      msg = msg.copyWith(
          expiresAt: msg.time.add(Duration(seconds: ttl)));
    }
    _replace(
      i,
      _chats[i].copyWith(messages: [..._chats[i].messages, msg]),
    );
  }

  /// Sets (or clears, with 0) the disappearing-messages timer for a chat.
  void setDisappearing(String chatId, int seconds) {
    final i = _indexOf(chatId);
    if (i != -1) {
      _replace(i, _chats[i].copyWith(disappearingSeconds: seconds));
    }
  }

  /// Removes any messages whose expiry has passed. Returns the number deleted.
  /// [now] is injectable for tests.
  int sweepExpired([DateTime? now]) {
    final at = now ?? DateTime.now();
    var removed = 0;
    for (var i = 0; i < _chats.length; i++) {
      final msgs = _chats[i].messages;
      final kept = msgs
          .where((m) => m.expiresAt == null || m.expiresAt!.isAfter(at))
          .toList();
      if (kept.length != msgs.length) {
        removed += msgs.length - kept.length;
        _chats[i] = _chats[i].copyWith(messages: kept);
      }
    }
    if (removed > 0) notifyListeners();
    return removed;
  }

  void replaceMessages(String chatId, List<Message> messages) {
    final i = _indexOf(chatId);
    if (i == -1) return;
    _replace(i, _chats[i].copyWith(messages: messages));
  }

  /// Upgrades the delivery status of the user's own (outgoing) messages in a
  /// chat to at least [status] — used to apply delivered/read receipts.
  void setOutgoingStatus(String chatId, MessageStatus status) {
    final i = _indexOf(chatId);
    if (i == -1) return;
    var changed = false;
    final msgs = _chats[i].messages.map((m) {
      if (m.isMe && m.status.index < status.index) {
        changed = true;
        return m.copyWith(status: status);
      }
      return m;
    }).toList();
    if (changed) _replace(i, _chats[i].copyWith(messages: msgs));
  }

  /// Removes every message from a conversation (keeps the chat itself).
  void clearMessages(String chatId) {
    final i = _indexOf(chatId);
    if (i == -1) return;
    _replace(i, _chats[i].copyWith(messages: const [], clearPinned: true));
  }

  /// Replaces a message's text and marks it edited.
  void editMessage(String chatId, String messageId, String newText) {
    final i = _indexOf(chatId);
    if (i == -1) return;
    final msgs = _chats[i].messages
        .map((m) =>
            m.id == messageId ? m.copyWith(text: newText, edited: true) : m)
        .toList();
    _replace(i, _chats[i].copyWith(messages: msgs));
  }

  void deleteMessage(String chatId, String messageId) {
    final i = _indexOf(chatId);
    if (i == -1) return;
    final msgs = _chats[i].messages.where((m) => m.id != messageId).toList();
    final clearPin = _chats[i].pinnedMessageId == messageId;
    _replace(i, _chats[i].copyWith(messages: msgs, clearPinned: clearPin));
  }

  void pinMessage(String chatId, String messageId) {
    final i = _indexOf(chatId);
    if (i != -1) {
      _replace(i, _chats[i].copyWith(pinnedMessageId: messageId));
    }
  }

  /// Records the local user's vote on a poll message, moving their tally from
  /// any previous choice. Returns the option index they previously held (-1 if
  /// none), so callers can broadcast the delta.
  int votePoll(String chatId, String messageId, int option) {
    final i = _indexOf(chatId);
    if (i == -1) return -1;
    var previous = -1;
    final msgs = _chats[i].messages.map((m) {
      if (m.id != messageId || !m.isPoll) return m;
      if (option < 0 || option >= m.pollOptions.length) return m;
      previous = m.pollMyVote;
      if (previous == option) return m; // already voted this option
      final votes = [...m.pollVotes];
      while (votes.length < m.pollOptions.length) {
        votes.add(0);
      }
      if (previous >= 0 && previous < votes.length && votes[previous] > 0) {
        votes[previous]--;
      }
      votes[option]++;
      return m.copyWith(pollVotes: votes, pollMyVote: option);
    }).toList();
    _replace(i, _chats[i].copyWith(messages: msgs));
    return previous;
  }

  /// Applies a remote peer's poll vote (increment [addOption], decrement an
  /// optional [removeOption]) without touching this device's own choice.
  void applyRemotePollVote(String chatId, String messageId, int addOption,
      int removeOption) {
    final i = _indexOf(chatId);
    if (i == -1) return;
    final msgs = _chats[i].messages.map((m) {
      if (m.id != messageId || !m.isPoll) return m;
      final votes = [...m.pollVotes];
      while (votes.length < m.pollOptions.length) {
        votes.add(0);
      }
      if (removeOption >= 0 &&
          removeOption < votes.length &&
          votes[removeOption] > 0) {
        votes[removeOption]--;
      }
      if (addOption >= 0 && addOption < votes.length) votes[addOption]++;
      return m.copyWith(pollVotes: votes);
    }).toList();
    _replace(i, _chats[i].copyWith(messages: msgs));
  }

  void unpinMessage(String chatId) {
    final i = _indexOf(chatId);
    if (i != -1) _replace(i, _chats[i].copyWith(clearPinned: true));
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

  /// Forces [emoji] on a message to [present] (used to mirror a peer's
  /// reaction received over the relay).
  void setReactionState(
      String chatId, String messageId, String emoji, bool present) {
    final i = _indexOf(chatId);
    if (i == -1) return;
    var changed = false;
    final msgs = _chats[i].messages.map((m) {
      if (m.id != messageId) return m;
      final reactions = List<String>.from(m.reactions);
      final has = reactions.contains(emoji);
      if (present && !has) {
        reactions.add(emoji);
      } else if (!present && has) {
        reactions.remove(emoji);
      } else {
        return m;
      }
      changed = true;
      return m.copyWith(reactions: reactions);
    }).toList();
    if (changed) _replace(i, _chats[i].copyWith(messages: msgs));
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
