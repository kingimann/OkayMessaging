import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../relay/relay_config.dart';
import 'ai_attachment.dart';
import 'ai_consent.dart';
import 'ai_memory.dart';
import 'ai_pass_store.dart';
import 'ai_persona.dart';
import 'on_device_draft.dart';
import 'platform_moderation.dart';

/// The lightweight record of an attachment kept in a saved turn — for display
/// only, never the full image or file text, which would bloat local storage.
/// For an image a small [thumb] is kept so the bubble still shows it.
@immutable
class AiAttachmentRef {
  final String kind; // 'image' | 'text'
  final String name;
  final String thumb; // small data: URI for an image, '' otherwise
  const AiAttachmentRef(
      {required this.kind, required this.name, this.thumb = ''});

  bool get isImage => kind == 'image';

  Map<String, dynamic> toJson() =>
      {'k': kind, 'n': name, if (thumb.isNotEmpty) 'th': thumb};

  factory AiAttachmentRef.fromJson(Map<String, dynamic> j) => AiAttachmentRef(
        kind: j['k'] as String? ?? 'text',
        name: j['n'] as String? ?? 'Attachment',
        thumb: j['th'] as String? ?? '',
      );
}

/// One turn in the assistant conversation.
class AiTurn {
  final bool fromUser;
  final String text;
  final DateTime time;

  /// The user's rating of an assistant reply: 0 none, 1 👍, -1 👎. The curation
  /// signal for training — only a rated (usually thumbs-up) exchange is worth
  /// keeping. Always 0 on a user turn.
  final int rating;

  /// Attachments the user sent with this turn (images/files). Display refs
  /// only; the bytes went to the model at send time and aren't re-sent.
  final List<AiAttachmentRef> attachments;

  const AiTurn(
      {required this.fromUser,
      required this.text,
      required this.time,
      this.rating = 0,
      this.attachments = const []});

  AiTurn withRating(int r) => AiTurn(
      fromUser: fromUser,
      text: text,
      time: time,
      rating: r,
      attachments: attachments);

  Map<String, dynamic> toJson() => {
        'u': fromUser,
        't': text,
        'at': time.toIso8601String(),
        if (rating != 0) 'r': rating,
        if (attachments.isNotEmpty)
          'a': [for (final a in attachments) a.toJson()],
      };

  factory AiTurn.fromJson(Map<String, dynamic> j) => AiTurn(
        fromUser: j['u'] as bool? ?? false,
        text: j['t'] as String? ?? '',
        time: DateTime.tryParse(j['at'] as String? ?? '') ?? DateTime(2024),
        rating: (j['r'] as num?)?.toInt() ?? 0,
        attachments: [
          for (final a in (j['a'] as List<dynamic>? ?? const []))
            AiAttachmentRef.fromJson(Map<String, dynamic>.from(a as Map))
        ],
      );
}

/// One saved conversation with Okay AI — a thread in the history list, the way
/// ChatGPT, Claude and Grok keep a sidebar of past chats. Holds its own turns
/// and a title (auto-drawn from the first thing the user said, unless renamed).
class AiConversation {
  AiConversation({
    required this.id,
    required this.createdAt,
    required this.updatedAt,
    this.title = '',
    List<AiTurn>? turns,
  }) : turns = turns ?? [];

  final String id;
  String title;
  DateTime createdAt;
  DateTime updatedAt;
  final List<AiTurn> turns;

  /// The first line of the first thing the user typed — what a thread is called
  /// when it hasn't been renamed, the same idea as a note's first-line title.
  String get autoTitle {
    for (final t in turns) {
      if (t.fromUser && t.text.trim().isNotEmpty) {
        final s = t.text.trim().split('\n').first.trim();
        return s.length > 40 ? '${s.substring(0, 40)}…' : s;
      }
    }
    return 'New chat';
  }

  /// What the history row shows: the given title, or the auto one.
  String get label => title.isNotEmpty ? title : autoTitle;

  /// A one-line preview for the history row — the last thing said.
  String get preview {
    for (final t in turns.reversed) {
      final s = t.text.trim();
      if (s.isNotEmpty) {
        final flat = s.split('\n').first.trim();
        return flat.length > 80 ? '${flat.substring(0, 80)}…' : flat;
      }
    }
    return '';
  }

  bool get isEmpty => turns.isEmpty;

  Map<String, dynamic> toJson() => {
        'id': id,
        if (title.isNotEmpty) 'title': title,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'turns': [for (final t in turns) t.toJson()],
      };

  factory AiConversation.fromJson(Map<String, dynamic> j) => AiConversation(
        id: j['id'] as String? ?? _mintId(),
        title: j['title'] as String? ?? '',
        createdAt:
            DateTime.tryParse(j['createdAt'] as String? ?? '') ?? DateTime(2024),
        updatedAt: DateTime.tryParse(j['updatedAt'] as String? ?? '') ??
            DateTime(2024),
        turns: [
          for (final t in (j['turns'] as List<dynamic>? ?? const []))
            AiTurn.fromJson(Map<String, dynamic>.from(t as Map))
        ],
      );
}

/// A short random id for a conversation. Not [DateTime]-based, so it works in
/// the test harness where the clock helpers are stubbed out.
String _mintId() {
  final n = _idCounter++;
  return 'c${n.toRadixString(36)}_${identityHashCode(Object())}';
}

int _idCounter = 0;

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

  /// Every saved conversation, most-recent last (order isn't relied on; the
  /// history list sorts by [AiConversation.updatedAt]). There is always at
  /// least one once [_ensureActive] has run.
  final List<AiConversation> _conversations = [];

  /// The conversation the screen is showing, when not incognito.
  AiConversation? _active;

  /// The ephemeral incognito thread — held in memory only, never saved and
  /// never in [_conversations].
  final List<AiTurn> _incognitoTurns = [];

  bool _sending = false;
  int _usedToday = 0;
  String _dayStamp = '';
  bool _incognito = false;

  /// The live turn list the screen reads and [send] appends to: the incognito
  /// thread when incognito, otherwise the active conversation's own turns.
  List<AiTurn> get _live {
    if (_incognito) return _incognitoTurns;
    _ensureActive();
    return _active!.turns;
  }

  /// Guarantees an active saved conversation exists — created lazily so a bare
  /// [send] (no [load]) still has somewhere to write, as the tests do.
  void _ensureActive() {
    if (_active != null) return;
    if (_conversations.isNotEmpty) {
      _active = _mostRecent();
    } else {
      final c = AiConversation(
          id: _mintId(), createdAt: DateTime.now(), updatedAt: DateTime.now());
      _conversations.add(c);
      _active = c;
    }
  }

  AiConversation _mostRecent() {
    var best = _conversations.first;
    for (final c in _conversations) {
      if (c.updatedAt.isAfter(best.updatedAt)) best = c;
    }
    return best;
  }

  AiConversation? _byId(String id) {
    for (final c in _conversations) {
      if (c.id == id) return c;
    }
    return null;
  }

  List<AiTurn> get turns => List.unmodifiable(_live);
  bool get sending => _sending;
  bool get isEmpty => _live.isEmpty;

  /// The saved conversations, newest first — what the history list shows. The
  /// ephemeral incognito thread is deliberately never among them.
  List<AiConversation> get conversations {
    final list = [..._conversations];
    list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return List.unmodifiable(list);
  }

  /// The id of the conversation on screen, so the history list can mark it.
  /// Empty in incognito (that thread isn't in the list).
  String get activeConversationId => _incognito ? '' : (_active?.id ?? '');

  /// Starts a fresh conversation and makes it active. Reuses the current one if
  /// it's already an empty "New chat", so tapping New chat twice doesn't stack
  /// blank threads. Leaves incognito, since a saved chat is the opposite of it.
  Future<void> newConversation() async {
    if (_incognito) _incognito = false;
    _incognitoTurns.clear();
    _ensureActive();
    if (_active!.turns.isEmpty) {
      notifyListeners();
      return;
    }
    final c = AiConversation(
        id: _mintId(), createdAt: DateTime.now(), updatedAt: DateTime.now());
    _conversations.add(c);
    _active = c;
    notifyListeners();
    await _save();
  }

  /// Switches to a saved conversation by id (leaving incognito if it was on).
  Future<void> switchTo(String id) async {
    final c = _byId(id);
    if (c == null) return;
    _incognito = false;
    _incognitoTurns.clear();
    _active = c;
    notifyListeners();
    await _save();
  }

  /// Removes a saved conversation. If it was the active one, falls back to the
  /// most recent remaining, or a fresh empty thread when none are left.
  Future<void> deleteConversation(String id) async {
    _conversations.removeWhere((c) => c.id == id);
    if (_active?.id == id) {
      _active = null;
      _ensureActive();
    }
    notifyListeners();
    await _save();
  }

  /// Renames a conversation; an empty title falls back to the auto one.
  Future<void> renameConversation(String id, String title) async {
    final c = _byId(id);
    if (c == null) return;
    c.title = title.trim();
    notifyListeners();
    await _save();
  }

  /// Incognito: an ephemeral session that is never written to the device and
  /// never reaches the learning path. While it's on, the conversation lives in
  /// memory only (no history saved), no on-device memory is sent as context or
  /// folded back in, the model is told `learn: false`, and nothing is eligible
  /// for the training corpus. The daily allowance still counts — incognito is
  /// about not remembering, not about being free. The DAY the request is made
  /// still leaves the server's own usage/IP trail (an honest limit); this hides
  /// it on the device, not from the host.
  bool get incognito => _incognito;

  /// Enters/leaves incognito. Entering starts a fresh ephemeral thread and
  /// leaves the saved conversation untouched on disk; leaving discards the
  /// ephemeral thread and brings the saved one back.
  Future<void> setIncognito(bool on) async {
    if (on == _incognito) return;
    _incognito = on;
    // Entering starts a fresh ephemeral thread; the saved conversations stay in
    // memory untouched. Leaving discards the ephemeral thread and shows the
    // active saved conversation again — no disk read needed, it never left.
    _incognitoTurns.clear();
    if (on) _ensureActive(); // so there's a saved chat to return to
    notifyListeners();
  }

  /// Whether this account is never rate-limited: a pass makes it unlimited,
  /// and so does being the app OWNER — the operator shouldn't pay their own
  /// gate. (Owner status is server-verified and false until it loads, so it's
  /// the safe way round.) The server enforces the real ceiling separately via
  /// AI_DAILY_CAP + AI_OWNER_PHONES.
  bool get _unlimited =>
      AiPassStore.instance.active || PlatformModeration.instance.isOwner;

  /// Free messages left today (a big number when a pass or owner status makes
  /// it unlimited).
  int get remainingFreeToday {
    if (_unlimited) return 1 << 30;
    _rollDay();
    final left = freePerDay - _usedToday;
    return left < 0 ? 0 : left;
  }

  /// Whether the free daily allowance is spent and nothing lifts it — the
  /// point where the UI shows the upgrade gate instead of sending.
  bool get needsUpgrade {
    if (_unlimited) return false;
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
      _conversations.clear();
      _active = null;
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          // The current shape: { active, items: [conversation, …] }.
          for (final c in (decoded['items'] as List<dynamic>? ?? const [])) {
            _conversations
                .add(AiConversation.fromJson(Map<String, dynamic>.from(c)));
          }
          final activeId = decoded['active'] as String? ?? '';
          _active = _byId(activeId);
        } else if (decoded is List) {
          // The legacy shape: a single flat list of turns. Fold it into one
          // conversation so an upgrading device keeps its one thread.
          final turns = [
            for (final e in decoded)
              AiTurn.fromJson(Map<String, dynamic>.from(e as Map))
          ];
          if (turns.isNotEmpty) {
            _conversations.add(AiConversation(
                id: _mintId(),
                createdAt: turns.first.time,
                updatedAt: turns.last.time,
                turns: turns));
          }
        }
      }
      _ensureActive();
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
    // Incognito never persists: the ephemeral thread must not reach disk, and
    // this guard also stops a clear() mid-incognito from overwriting the real
    // saved conversation with the empty ephemeral one.
    if (_incognito) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _kKey,
          jsonEncode({
            'active': _active?.id ?? '',
            'items': [for (final c in _conversations) c.toJson()],
          }));
    } catch (_) {}
  }

  /// Sends [text] to the assistant and appends its reply. The user turn shows
  /// immediately; a failure appends an honest error turn rather than throwing,
  /// so the chat never dead-ends. Returns whether a reply came back.
  ///
  /// [attachments] are images/files the user handed to the assistant with this
  /// message: an image rides to a vision model as a `data:` URL, a text file's
  /// content is folded in. They travel with THIS turn only — older images are
  /// not re-sent — and are the one thing besides the user's own words that
  /// reaches the model.
  Future<bool> send(String text,
      {List<AiAttachment> attachments = const []}) async {
    final t = text.trim();
    if ((t.isEmpty && attachments.isEmpty) || _sending) return false;
    // The pay gate: past the free daily allowance, a pass is required. The UI
    // checks [needsUpgrade] first and shows the gate; this is the backstop.
    if (needsUpgrade) return false;

    _live.add(AiTurn(
      fromUser: true,
      text: t,
      time: DateTime.now(),
      attachments: [
        for (final a in attachments)
          AiAttachmentRef(kind: a.kind, name: a.name, thumb: a.thumbDataUri)
      ],
    ));
    _touchActive();
    _sending = true;
    _rollDay();
    _usedToday++;
    notifyListeners();
    await _save();
    await _saveUsage();

    final payload = <Map<String, dynamic>>[
      for (final turn in _live.length > _maxContext
          ? _live.sublist(_live.length - _maxContext)
          : _live)
        {'role': turn.fromUser ? 'user' : 'assistant', 'content': turn.text}
    ];
    // The just-sent turn carries the images/files as multimodal content; every
    // earlier turn stays plain text (old images are never re-sent).
    if (attachments.isNotEmpty && payload.isNotEmpty) {
      payload[payload.length - 1]['content'] =
          _multimodalContent(t, attachments);
    }

    String? reply;
    List<String> newMemories = const [];
    bool configured = true;
    bool rateLimited = false;
    try {
      final override = debugReplyOverride;
      if (override != null) {
        reply = await override(payload);
      } else {
        final client = _client;
        if (client == null) {
          configured = false;
        } else {
          final style = AiPersona.instance.instruction;
          final res = await client.functions.invoke('ai-chat', body: {
            'messages': payload,
            // The user's on-device memory, so the assistant "knows" them —
            // withheld in incognito, along with the learning turn.
            if (!_incognito) 'memories': AiMemory.instance.items,
            'learn': !_incognito,
            // The chosen personality/tone, when it isn't the default voice.
            if (style.isNotEmpty) 'style': style,
          });
          final data = res.data;
          if (data is Map) {
            configured = data['configured'] != false;
            if (data['error'] == 'rate_limited') rateLimited = true;
            final r = data['reply'];
            if (r is String && r.trim().isNotEmpty) reply = r.trim();
            final mem = data['memories'];
            if (mem is List) {
              newMemories = [for (final m in mem) m.toString()];
            }
          }
        }
      }
    } catch (e) {
      // The functions client throws on a non-2xx; the server's daily ceiling
      // returns 429, which reads as a rate-limit here.
      if ('$e'.contains('429') || '$e'.contains('rate_limited')) {
        rateLimited = true;
      }
      reply = null;
    }

    _sending = false;
    // Fold anything worth remembering into the on-device memory — how it
    // "learns" about this user, per user, never leaving the device. Skipped in
    // incognito: an incognito turn leaves no trace, here included.
    if (!_incognito && newMemories.isNotEmpty) {
      await AiMemory.instance.addAll(newMemories);
    }
    if (reply != null) {
      _live.add(AiTurn(fromUser: false, text: reply, time: DateTime.now()));
    } else {
      _live.add(AiTurn(
        fromUser: false,
        text: rateLimited
            ? 'You\'ve reached today\'s limit for Okay AI. Try again '
                'tomorrow, or subscribe for more.'
            : configured
                ? 'Sorry — I couldn\'t answer just now. Please try again.'
                : 'The assistant isn\'t set up on this server yet.',
        time: DateTime.now(),
      ));
    }
    _touchActive();
    notifyListeners();
    await _save();
    return reply != null;
  }

  /// Marks the active saved conversation as just-used, so it sorts to the top
  /// of the history list. A no-op in incognito (nothing is saved there).
  void _touchActive() {
    if (_incognito) return;
    _active?.updatedAt = DateTime.now();
  }

  /// Builds the OpenRouter multimodal `content` array for a message that
  /// carries attachments: the user's typed text plus any text files folded in
  /// as one text part, then one `image_url` part per image. When nothing was
  /// typed, a neutral instruction stands in so the model has a prompt.
  static List<Map<String, dynamic>> _multimodalContent(
      String text, List<AiAttachment> attachments) {
    final buffer = StringBuffer(text.trim());
    for (final a in attachments.where((a) => a.kind == 'text')) {
      if (buffer.isNotEmpty) buffer.write('\n\n');
      buffer.write('--- Attached file: ${a.name} ---\n${a.text}');
    }
    final images = attachments.where((a) => a.isImage).toList();
    var textPart = buffer.toString().trim();
    if (textPart.isEmpty) {
      textPart = images.isNotEmpty
          ? 'Please look at the attached image.'
          : 'Please review the attached file.';
    }
    return [
      {'type': 'text', 'text': textPart},
      for (final a in images)
        {
          'type': 'image_url',
          'image_url': {'url': a.imageDataUri}
        },
    ];
  }

  /// A ONE-SHOT draft from an instruction, for the "write a message for me"
  /// button in a chat. Sends ONLY [instruction] — never the conversation, so
  /// no encrypted chat content reaches the model — and returns the drafted
  /// text (or null on failure). Does not touch the assistant conversation.
  ///
  /// Tries the ON-DEVICE model first ([OnDeviceDraft], Apple's model running
  /// in-process) and only reaches for the hosted `ai-chat` function when the
  /// device declines — no Apple Intelligence, older hardware, or a guardrail
  /// refusal. This is the one Okay AI path both sides can answer, because it
  /// is the one already shaped as a single instruction in, a single reply
  /// out with no memory either side: the hosted prompt below is unchanged so
  /// the fallback reads identically to a caller either way. Going on-device
  /// costs this device nothing and never counts against `AI_DAILY_CAP` or the
  /// free-tier limit — it never reaches the server at all.
  Future<String?> draft(String instruction) async {
    final t = instruction.trim();
    if (t.isEmpty) return null;
    final onDevice = await OnDeviceDraft.instance.draft(t);
    if (onDevice != null) return onDevice;
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

  /// Rates the assistant reply at [index] (1 👍, -1 👎, 0 to clear). The rating
  /// shows locally at once; when the user has opted in to helping improve Okay
  /// AI ([AiConsent]), the exchange — the prompting message and the reply —
  /// plus the rating is sent to the training corpus via the `ai-feedback`
  /// function. Without consent nothing is uploaded. Returns whether it was
  /// submitted server-side.
  Future<bool> rate(int index, int rating) async {
    if (index < 0 || index >= _live.length || _live[index].fromUser) {
      return false;
    }
    // Toggle off if the same rating is tapped again.
    final applied = _live[index].rating == rating ? 0 : rating;
    _live[index] = _live[index].withRating(applied);
    notifyListeners();
    await _save();

    // Incognito never contributes to the training corpus, consent or not.
    if (applied == 0 || _incognito || !AiConsent.instance.on) return false;
    final prompt = index > 0 ? _live[index - 1].text : '';
    final reply = _live[index].text;
    if (prompt.trim().isEmpty || reply.trim().isEmpty) return false;
    try {
      final override = debugFeedbackOverride;
      if (override != null) {
        await override(prompt, reply, applied);
        return true;
      }
      final client = _client;
      if (client == null) return false;
      await client.functions.invoke('ai-feedback',
          body: {'prompt': prompt, 'reply': reply, 'rating': applied});
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Empties the conversation on screen (local only — nothing is stored
  /// server-side). It stays in the history list as a fresh "New chat"; to
  /// remove a thread entirely, use [deleteConversation].
  Future<void> clear() async {
    _live.clear();
    _touchActive();
    notifyListeners();
    await _save();
  }

  /// Stands in for the Edge Function call in tests. Content is `String` for a
  /// plain message or a `List` of parts for one carrying attachments, so the
  /// value type is dynamic.
  @visibleForTesting
  static Future<String?> Function(List<Map<String, dynamic>> messages)?
      debugReplyOverride;

  /// Stands in for the feedback submission in tests.
  @visibleForTesting
  static Future<void> Function(String prompt, String reply, int rating)?
      debugFeedbackOverride;

  @visibleForTesting
  void resetForTest() {
    _conversations.clear();
    _active = null;
    _incognitoTurns.clear();
    _sending = false;
    _usedToday = 0;
    _dayStamp = '';
    _incognito = false;
    debugReplyOverride = null;
    debugFeedbackOverride = null;
  }
}
