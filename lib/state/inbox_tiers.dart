import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/chat.dart';

/// The three buckets a chat auto-sorts into: Priority (people you actually
/// talk with), General (everyone else, groups included), and Occasional
/// (businesses and one-time codes) — a Smart Inbox for the chat list.
enum InboxTier {
  priority,
  general,
  occasional;

  String get label => switch (this) {
        InboxTier.priority => 'Priority',
        InboxTier.general => 'General',
        InboxTier.occasional => 'Occasional',
      };

  String get description => switch (this) {
        InboxTier.priority =>
          'Favourites, pinned chats, and people you talk with both ways',
        InboxTier.general => 'Groups and everyone else',
        InboxTier.occasional =>
          'Businesses and messages that look like a one-time code',
      };
}

/// Pure classification rules — no store, no state, so a test can hand it a
/// [Chat] and check the tier directly. [InboxTiers] is the thin store on top
/// that lets a person override what the rule would have said.
class InboxTiering {
  InboxTiering._();

  /// How far back a reciprocal 1:1 still counts as "recent" for Priority.
  /// A test seam, like `debugRounds` elsewhere — mutable so a test can shrink
  /// it rather than fake the clock.
  @visibleForTesting
  static Duration recentWindow = const Duration(days: 30);

  /// A one-time code reads the same everywhere: a short run of digits, or
  /// the words that always ride with one. Matched loosely on purpose — a
  /// false "Occasional" costs one tap to move the chat back (General shows
  /// it just as well); a missed one costs nothing.
  static final RegExp _otpLike = RegExp(
    r'\b\d{4,8}\b|verification code|one[- ]time (code|password)|is your code\b|\botp\b',
    caseSensitive: false,
  );

  static bool looksLikeOtp(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;
    return _otpLike.hasMatch(trimmed);
  }

  /// The rule-based tier for [chat] — ignores any manual override; see
  /// [InboxTiers.tierFor] for the tier a chat actually shows under.
  ///
  /// A rule, not a mystery: favourited or pinned always wins (an explicit
  /// choice always outranks a guess), then a real back-and-forth in a 1:1
  /// within [recentWindow], then a business contact or a code-shaped last
  /// message, and everything left over — groups included — lands in
  /// General, the same place it always would have shown up.
  static InboxTier autoTierFor(Chat chat, {DateTime? now}) {
    if (chat.isFavorite || chat.isPinned) return InboxTier.priority;
    if (!chat.contact.isGroup && _hasRecentReciprocalHistory(chat, now)) {
      return InboxTier.priority;
    }
    if (chat.contact.isBusiness) return InboxTier.occasional;
    final last = chat.lastMessage;
    if (last != null && !last.isMe && looksLikeOtp(last.text)) {
      return InboxTier.occasional;
    }
    return InboxTier.general;
  }

  static bool _hasRecentReciprocalHistory(Chat chat, DateTime? now) {
    final last = chat.lastMessage;
    if (last == null) return false;
    final clock = now ?? DateTime.now();
    if (clock.difference(last.time) > recentWindow) return false;
    var sentByMe = false;
    var sentByThem = false;
    for (final m in chat.messages) {
      if (m.isMe) {
        sentByMe = true;
      } else {
        sentByThem = true;
      }
      if (sentByMe && sentByThem) return true;
    }
    return false;
  }
}

/// Per-chat manual tier overrides, device-local like [ChatFolders] and
/// [MessageSoundStore] — which tier somebody sorts a conversation into is a
/// statement about their life, not a fact the server needs.
///
/// Membership here is a RULE, unlike a folder's explicit list — the trade
/// [ChatFolders] deliberately avoided. Rules are worth the "quietly pulls a
/// chat somewhere new" risk here only because every rule is stated in
/// [InboxTier.description] and every chat can be moved back in one tap; a
/// folder with no such override would just be a rule with no way out.
class InboxTiers extends ChangeNotifier {
  InboxTiers._();
  static final InboxTiers instance = InboxTiers._();

  static const _key = 'inbox_tier_overrides_v1';

  SharedPreferences? _prefs;
  final Map<String, InboxTier> _overrides = {};

  /// Null when [chatId] has no override and just follows the rule.
  InboxTier? overrideFor(String chatId) => _overrides[chatId];

  /// The tier [chat] actually shows under: its own override, or the rule.
  InboxTier tierFor(Chat chat, {DateTime? now}) =>
      _overrides[chat.id] ?? InboxTiering.autoTierFor(chat, now: now);

  Future<void> load() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    _overrides.clear();
    final raw = prefs.getString(_key);
    if (raw != null) {
      try {
        final map = Map<String, dynamic>.from(jsonDecode(raw) as Map);
        for (final e in map.entries) {
          final t = _byName(e.value as String?);
          if (t != null) _overrides[e.key] = t;
        }
      } catch (_) {
        // A corrupt blob costs the overrides, never the chats.
      }
    }
    notifyListeners();
  }

  static InboxTier? _byName(String? name) {
    for (final t in InboxTier.values) {
      if (t.name == name) return t;
    }
    return null;
  }

  /// Sets [chatId]'s tier, or clears it back to the rule when [tier] is null.
  Future<void> setOverride(String chatId, InboxTier? tier) async {
    if (tier == null) {
      _overrides.remove(chatId);
    } else {
      _overrides[chatId] = tier;
    }
    await _persist();
    notifyListeners();
  }

  /// A chat that's gone keeps no orphaned override.
  Future<void> forget(String chatId) async {
    if (_overrides.remove(chatId) != null) {
      await _persist();
      notifyListeners();
    }
  }

  Future<void> _persist() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    await prefs.setString(
        _key, jsonEncode({for (final e in _overrides.entries) e.key: e.value.name}));
  }

  @visibleForTesting
  void resetForTest() {
    _overrides.clear();
    _prefs = null;
  }
}
