import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The message-sound choices this app can offer without bundling any audio
/// files: the two iOS System Sound IDs the call ringer already plays
/// (`ios/Runner/AppDelegate.swift`'s `okay/ringtone` channel), plus
/// vibrate-only and silent. A wider catalog needs a real device to confirm
/// an additional system sound ID actually sounds right before it's added —
/// see CLAUDE.md.
enum MessageSound {
  chirp('Chirp', 1007),
  ringBackBeat('Ring-back beat', 1074),
  vibrate('Vibrate only', -1),
  silent('Silent', 0);

  const MessageSound(this.label, this.systemSoundId);
  final String label;
  final int systemSoundId;
}

/// Per-chat and default message-sound preferences, and the one place that
/// plays them.
///
/// Deliberately narrow in scope: this plays ONLY for the chat you have OPEN
/// when a message arrives in it — the one moment the app is already
/// completely silent (`PushService.setOpenChat` suppresses the push banner,
/// and with it the OS's own default sound, for whichever chat is on
/// screen). Every OTHER chat already gets the OS's standard notification
/// sound via the push banner while the app is foregrounded; adding a second,
/// different sound there would mean two chimes for one message, which is
/// worse than the one this fills a real gap in.
class MessageSoundStore extends ChangeNotifier {
  MessageSoundStore._();
  static final MessageSoundStore instance = MessageSoundStore._();

  static const _channel = MethodChannel('okay/ringtone');
  static const _defaultKey = 'message_sound_default_v1';
  static const _perChatKey = 'message_sound_per_chat_v1';

  SharedPreferences? _prefs;
  MessageSound _default = MessageSound.chirp;
  final Map<String, MessageSound> _perChat = {};

  MessageSound get defaultSound => _default;

  /// The sound for [chatId]: its own override, or the app-wide default.
  MessageSound soundFor(String chatId) => _perChat[chatId] ?? _default;

  /// Null when [chatId] has no override and just follows the default.
  MessageSound? overrideFor(String chatId) => _perChat[chatId];

  Future<void> load() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    final d = prefs.getString(_defaultKey);
    _default = _byName(d) ?? MessageSound.chirp;
    _perChat.clear();
    final raw = prefs.getString(_perChatKey);
    if (raw != null) {
      try {
        final map = Map<String, dynamic>.from(jsonDecode(raw) as Map);
        for (final e in map.entries) {
          final s = _byName(e.value as String?);
          if (s != null) _perChat[e.key] = s;
        }
      } catch (_) {}
    }
    notifyListeners();
  }

  static MessageSound? _byName(String? name) {
    for (final s in MessageSound.values) {
      if (s.name == name) return s;
    }
    return null;
  }

  Future<void> setDefault(MessageSound s) async {
    _default = s;
    await _prefs?.setString(_defaultKey, s.name);
    notifyListeners();
  }

  /// Sets [chatId]'s own sound, or clears it back to following the default
  /// when [s] is null.
  Future<void> setForChat(String chatId, MessageSound? s) async {
    if (s == null) {
      _perChat.remove(chatId);
    } else {
      _perChat[chatId] = s;
    }
    await _persistPerChat();
    notifyListeners();
  }

  /// A chat that's gone keeps no orphaned override.
  Future<void> forget(String chatId) async {
    if (_perChat.remove(chatId) != null) {
      await _persistPerChat();
      notifyListeners();
    }
  }

  Future<void> _persistPerChat() async {
    await _prefs?.setString(_perChatKey,
        jsonEncode({for (final e in _perChat.entries) e.key: e.value.name}));
  }

  /// Test hook: stands in for the native channel (which no test platform
  /// answers), so a test can see what would have played without faking
  /// `defaultTargetPlatform`.
  @visibleForTesting
  static void Function(MessageSound sound)? debugPlayOverride;

  /// Plays the sound for [chatId] — a no-op off iOS, for the silent choice,
  /// or when the native side is missing (simulator, an older binary).
  Future<void> play(String chatId) => previewSound(soundFor(chatId));

  /// Plays [s] directly — the picker's preview button, and what [play]
  /// itself resolves a chat's sound to before playing it.
  Future<void> previewSound(MessageSound s) async {
    if (s == MessageSound.silent) return;
    final hook = debugPlayOverride;
    if (hook != null) {
      hook(s);
      return;
    }
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
    try {
      await _channel.invokeMethod<void>('playSound', s.systemSoundId);
    } catch (_) {}
  }

  @visibleForTesting
  void resetForTest() {
    _default = MessageSound.chirp;
    _perChat.clear();
    _prefs = null;
    notifyListeners();
  }
}
