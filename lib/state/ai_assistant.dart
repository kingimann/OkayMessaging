import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../relay/relay_config.dart';
import 'ai_memory.dart';
import 'ai_pass_store.dart';

/// One turn in the assistant conversation.
class AiTurn {
  final bool fromUser;
  final String text;
  final DateTime time;
  const AiTurn(
      {required this.fromUser, required this.text, required this.time});

  Map<String, dynamic> toJson() =>
      {'u': fromUser, 't': text, 'at': time.toIso8601String()};

  factory AiTurn.fromJson(Map<String, dynamic> j) => AiTurn(
        fromUser: j['u'] as bool? ?? false,
        text: j['t'] as String? ?? '',
        time: DateTime.tryParse(j['at'] as String? ?? '') ?? DateTime(2024),
      );
}

/// The app's built-in AI assistant — "Okay AI", a general-purpose helper in the
/// shape of Grok or Claude.
///
/// KNOWINGLY HOSTED, AND WALLED OFF. Unlike a human chat — whose contents are
/// end-to-end encrypted and must never reach a server that can read them — the
/// user here is deliberately talking to an assistant, so what they type goes to
/// a hosted model through the `ai-chat` Edge Function (the API key stays
/// server-side). It only ever sees what is typed into THIS conversation; it is
/// never wired to a human-to-human chat, a server feed, or any encrypted
/// content. That boundary is the whole reason this is allowed to exist beside
/// the app's "AI only on device" rule for chats.
class AiAssistant extends ChangeNotifier {
  AiAssistant._();
  static final AiAssistant instance = AiAssistant._();

  static const _kKey = 'ai_assistant_history_v1';

  /// The tail of the conversation sent to the model, bounded so a long thread
  /// can't send a novel each turn (the function bounds it again server-side).
  static const int _maxContext = 24;

  /// Messages a free (non-subscribed) account may send Okay AI per day, before
  /// the pay gate. Past this, an [AiPassStore] pass is needed. Generous enough
  /// to be useful, small enough to keep the per-token cost bounded.
  static const int freePerDay = 15;
  static const _kUsed = 'ai_used_v1';
  static const _kDay = 'ai_day_v1';

  final List<AiTurn> _turns = [];
  bool _sending = false;
  int _usedToday = 0;
  String _dayStamp = '';

  List<AiTurn> get turns => List.unmodifiable(_turns);
  bool get sending => _sending;
  bool get isEmpty => _turns.isEmpty;

  /// Free messages left today (a big number when a pass makes it unlimited).
  int get remainingFreeToday {
    if (AiPassStore.instance.active) return 1 << 30;
    _rollDay();
    final left = freePerDay - _usedToday;
    return left < 0 ? 0 : left;
  }

  /// Whether the free daily allowance is spent and no pass is active — the
  /// point where the UI shows the upgrade gate instead of sending.
  bool get needsUpgrade {
    if (AiPassStore.instance.active) return false;
    _rollDay();
    return _usedToday >= freePerDay;
  }

  /// Resets the day counter when the calendar date changes. Uses the local
  /// date only (no clock arithmetic), so a day boundary is unambiguous.
  void _rollDay() {
    final now = DateTime.now();
    final today = '${now.year}-${now.month}-${now.day}';
    if (_dayStamp != today) {
      _dayStamp = today;
      _usedToday = 0;
    }
  }

  SupabaseClient? get _client =>
      RelayConfig.isEnabled ? Supabase.instance.client : null;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kKey);
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw) as List<dynamic>;
        _turns
          ..clear()
          ..addAll(list.map(
              (e) => AiTurn.fromJson(Map<String, dynamic>.from(e as Map))));
      }
      _usedToday = prefs.getInt(_kUsed) ?? 0;
      _dayStamp = prefs.getString(_kDay) ?? '';
      _rollDay();
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _saveUsage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kUsed, _usedToday);
      await prefs.setString(_kDay, _dayStamp);
    } catch (_) {}
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _kKey, jsonEncode(_turns.map((t) => t.toJson()).toList()));
    } catch (_) {}
  }

  /// Sends [text] to the assistant and appends its reply. The user turn shows
  /// immediately; a failure appends an honest error turn rather than throwing,
  /// so the chat never dead-ends. Returns whether a reply came back.
  Future<bool> send(String text) async {
    final t = text.trim();
    if (t.isEmpty || _sending) return false;
    // The pay gate: past the free daily allowance, a pass is required. The UI
    // checks [needsUpgrade] first and shows the gate; this is the backstop.
    if (needsUpgrade) return false;

    _turns.add(AiTurn(fromUser: true, text: t, time: DateTime.now()));
    _sending = true;
    _rollDay();
    _usedToday++;
    notifyListeners();
    await _save();
    await _saveUsage();

    final payload = [
      for (final turn in _turns.length > _maxContext
          ? _turns.sublist(_turns.length - _maxContext)
          : _turns)
        {'role': turn.fromUser ? 'user' : 'assistant', 'content': turn.text}
    ];

    String? reply;
    List<String> newMemories = const [];
    bool configured = true;
    try {
      final override = debugReplyOverride;
      if (override != null) {
        reply = await override(payload);
      } else {
        final client = _client;
        if (client == null) {
          configured = false;
        } else {
          final res = await client.functions.invoke('ai-chat', body: {
            'messages': payload,
            // The user's on-device memory, so the assistant "knows" them.
            'memories': AiMemory.instance.items,
            'learn': true,
          });
          final data = res.data;
          if (data is Map) {
            configured = data['configured'] != false;
            final r = data['reply'];
            if (r is String && r.trim().isNotEmpty) reply = r.trim();
            final mem = data['memories'];
            if (mem is List) {
              newMemories = [for (final m in mem) m.toString()];
            }
          }
        }
      }
    } catch (_) {
      reply = null;
    }

    _sending = false;
    // Fold anything worth remembering into the on-device memory — how it
    // "learns" about this user, per user, never leaving the device.
    if (newMemories.isNotEmpty) {
      await AiMemory.instance.addAll(newMemories);
    }
    if (reply != null) {
      _turns.add(AiTurn(fromUser: false, text: reply, time: DateTime.now()));
    } else {
      _turns.add(AiTurn(
        fromUser: false,
        text: configured
            ? 'Sorry — I couldn\'t answer just now. Please try again.'
            : 'The assistant isn\'t set up on this server yet.',
        time: DateTime.now(),
      ));
    }
    notifyListeners();
    await _save();
    return reply != null;
  }

  /// A ONE-SHOT draft from an instruction, for the "write a message for me"
  /// button in a chat. Sends ONLY [instruction] — never the conversation, so
  /// no encrypted chat content reaches the model — and returns the drafted
  /// text (or null on failure). Does not touch the assistant conversation.
  Future<String?> draft(String instruction) async {
    final t = instruction.trim();
    if (t.isEmpty) return null;
    final payload = [
      {
        'role': 'user',
        'content':
            'Write a short message I can send in a chat. Reply with ONLY the '
                'message text, no preamble or quotes. What I want to say: $t',
      }
    ];
    try {
      final override = debugReplyOverride;
      if (override != null) return await override(payload);
      final client = _client;
      if (client == null) return null;
      // A pure utility: no memory in, no learning out.
      final res = await client.functions
          .invoke('ai-chat', body: {'messages': payload, 'learn': false});
      final data = res.data;
      if (data is Map) {
        final r = data['reply'];
        if (r is String && r.trim().isNotEmpty) return r.trim();
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Clears the conversation (local only — nothing is stored server-side).
  Future<void> clear() async {
    _turns.clear();
    notifyListeners();
    await _save();
  }

  /// Stands in for the Edge Function call in tests.
  @visibleForTesting
  static Future<String?> Function(List<Map<String, String>> messages)?
      debugReplyOverride;

  @visibleForTesting
  void resetForTest() {
    _turns.clear();
    _sending = false;
    _usedToday = 0;
    _dayStamp = '';
    debugReplyOverride = null;
  }
}
