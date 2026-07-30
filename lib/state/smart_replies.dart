import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/message.dart';

/// Three short replies the device suggests for the message you just received.
///
/// ON THE DEVICE, ALWAYS. This runs against Apple's on-device model through
/// `okay/smartreplies`; the conversation is read in the app's own process and
/// goes nowhere else. That is not a nice-to-have here — message bodies are
/// encrypted before they leave the device, so a cloud model would mean
/// decrypting somebody's chat somewhere we can read it, which is the one thing
/// this app promises never to happen. There is no network path in this file
/// and there must never be one.
///
/// The model is small and its context is about 4,000 tokens for the prompt and
/// the answer together, so only the tail of a conversation is ever sent — see
/// [_maxMessages] and [_maxChars].
class SmartReplies {
  SmartReplies._();

  static final SmartReplies instance = SmartReplies._();

  static const MethodChannel _channel = MethodChannel('okay/smartreplies');

  /// The tail of the conversation the model is shown. Twenty messages is well
  /// inside the context window with room for the instructions and the answer,
  /// and it is about as far back as a reply suggestion is relevant anyway.
  static const int _maxMessages = 20;

  /// A hard character ceiling on top of the message count, because twenty
  /// long messages would overflow where twenty short ones do not. Tokens are
  /// what actually count, and ~4 characters per token is the usual rule of
  /// thumb, so this leaves the model over half its window.
  static const int _maxChars = 4000;

  /// The longest a single message can be before it is trimmed. One pasted
  /// wall of text should not use up the whole budget on its own.
  static const int _maxCharsPerMessage = 400;

  bool? _available;

  /// Whether this device can suggest replies at all.
  ///
  /// False on the web build and on any iPhone without Apple Intelligence —
  /// which is most of them — so every caller has to handle "no" as the normal
  /// case rather than an error. Asked once and remembered: the answer cannot
  /// change while the app is running.
  Future<bool> get available async {
    if (_available != null) return _available!;
    if (debugAvailableOverride != null) return debugAvailableOverride!;
    // The channel does not exist on web or on Android; asking would throw.
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
      return _available = false;
    }
    try {
      final ok = await _channel.invokeMethod<bool>('available');
      return _available = ok ?? false;
    } on PlatformException {
      return _available = false;
    } on MissingPluginException {
      // An older build of the app shell without the channel compiled in.
      return _available = false;
    }
  }

  /// Suggestions for replying to [messages], or an empty list.
  ///
  /// Empty is a normal answer, not a failure: the device may not support it,
  /// the model may decline, or the conversation may not be at a point where a
  /// reply makes sense. Callers show nothing at all in that case — an invented
  /// suggestion would be words put in somebody's mouth.
  Future<List<String>> suggest({
    required List<Message> messages,
    required String contactName,
  }) async {
    if (!await available) return const [];

    final transcript = transcriptFor(messages, contactName);
    if (transcript.isEmpty) return const [];

    try {
      // The override stands in for the CHANNEL, not for this method, so
      // everything below runs in a test exactly as it runs on a phone. An
      // override that replaced the whole method would leave the cleaning
      // below covered by nothing.
      final override = debugSuggestOverride;
      final replies = override != null
          ? await override(messages, contactName)
          : await _channel.invokeListMethod<String>('suggest', {
              'transcript': transcript,
              'contact': contactName,
            });
      if (replies == null) return const [];
      // The model is asked for three short replies and usually gives three,
      // but nothing enforces that they are distinct or non-empty.
      final seen = <String>{};
      return [
        for (final r in replies)
          if (r.trim().isNotEmpty && seen.add(r.trim().toLowerCase())) r.trim(),
      ];
    } on PlatformException {
      // A guardrail refusal or a model that went away mid-request. Silent by
      // design: a failed suggestion is not worth a message to somebody who
      // never asked for one.
      return const [];
    } on MissingPluginException {
      return const [];
    }
  }

  /// Whether [messages] is a point in the conversation worth suggesting for.
  ///
  /// Only when the other person spoke last — suggesting a reply to your own
  /// message is answering yourself, and suggesting one when the conversation
  /// is empty is starting it for you.
  static bool worthSuggesting(List<Message> messages) =>
      messages.isNotEmpty && !messages.last.isMe;

  /// The tail of the conversation as plain lines, bounded both ways.
  ///
  /// Public for the test that proves the bound holds: the whole point of the
  /// cap is that it cannot be exceeded by a long conversation, and a limit
  /// nobody checks is a limit that drifts.
  @visibleForTesting
  static String transcriptFor(List<Message> messages, String contactName) {
    final name = contactName.trim().isEmpty ? 'Them' : contactName.trim();
    final lines = <String>[];
    var chars = 0;
    // Backwards from the most recent, so what gets dropped is the oldest.
    for (final m in messages.reversed.take(_maxMessages)) {
      final body = m.isVoice
          ? '(voice message)'
          : m.text.length > _maxCharsPerMessage
              ? '${m.text.substring(0, _maxCharsPerMessage)}…'
              : m.text;
      if (body.trim().isEmpty) continue;
      final line = '${m.isMe ? 'Me' : name}: $body';
      if (chars + line.length > _maxChars) break;
      chars += line.length;
      lines.add(line);
    }
    return lines.reversed.join('\n');
  }

  /// Test hooks. The real path needs an iPhone with Apple Intelligence, which
  /// no test runner has.
  @visibleForTesting
  static bool? debugAvailableOverride;

  /// Stands in for the platform channel's raw answer — including a null one.
  @visibleForTesting
  static Future<List<String>?> Function(List<Message> messages, String contact)?
      debugSuggestOverride;

  @visibleForTesting
  void resetForTest() {
    _available = null;
    debugAvailableOverride = null;
    debugSuggestOverride = null;
  }
}
