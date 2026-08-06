import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One personality option for Okay AI.
class PersonaPreset {
  final String id;
  final String label;
  final String blurb;

  /// The tone instruction sent to the model. Empty for the default, which
  /// sends no style line at all (the assistant's own voice).
  final String instruction;

  const PersonaPreset({
    required this.id,
    required this.label,
    required this.blurb,
    required this.instruction,
  });
}

/// The user's chosen personality for Okay AI. A tone preference, not a jailbreak:
/// the instruction is folded into the system prompt as a style the assistant
/// follows WHILE keeping its real limits (which the system prompt restates after
/// it). Persisted on the device; a `custom` option carries the user's own words.
///
/// It reaches the model only as the `style` field on the `ai-chat` request —
/// this store names no chat, relay or crypto, so like the rest of Okay AI it can
/// only ever see what the user picks here.
class AiPersona extends ChangeNotifier {
  AiPersona._();
  static final AiPersona instance = AiPersona._();

  static const _kId = 'ai_persona_id_v1';
  static const _kCustom = 'ai_persona_custom_v1';

  /// The built-in personalities. `custom` carries the user's own instruction.
  static const List<PersonaPreset> presets = [
    PersonaPreset(
      id: 'default',
      label: 'Default',
      blurb: 'Balanced and helpful — the assistant\'s own voice.',
      instruction: '',
    ),
    PersonaPreset(
      id: 'concise',
      label: 'Concise',
      blurb: 'Short and to the point.',
      instruction: 'Be brief and direct. Prefer short answers, lists and the '
          'essential facts over long prose.',
    ),
    PersonaPreset(
      id: 'friendly',
      label: 'Friendly',
      blurb: 'Warm and casual.',
      instruction: 'Be warm, casual and encouraging, in a conversational, '
          'first-name tone.',
    ),
    PersonaPreset(
      id: 'professional',
      label: 'Professional',
      blurb: 'Formal and precise.',
      instruction: 'Be formal, precise and professional, like a careful expert '
          'colleague.',
    ),
    PersonaPreset(
      id: 'playful',
      label: 'Playful',
      blurb: 'Witty, with a bit of humour.',
      instruction: 'Be witty and playful with light humour and the occasional '
          'emoji, while staying genuinely helpful and accurate.',
    ),
    PersonaPreset(
      id: 'custom',
      label: 'Custom',
      blurb: 'Describe the personality yourself.',
      instruction: '',
    ),
  ];

  static PersonaPreset presetFor(String id) =>
      presets.firstWhere((p) => p.id == id, orElse: () => presets.first);

  String _id = 'default';
  String _custom = '';

  String get id => _id;
  String get custom => _custom;
  PersonaPreset get selected => presetFor(_id);
  String get label => selected.label;

  /// The tone instruction to send with a message, or '' for the default.
  String get instruction =>
      _id == 'custom' ? _custom.trim() : selected.instruction;

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final id = p.getString(_kId) ?? 'default';
      _id = presets.any((e) => e.id == id) ? id : 'default';
      _custom = p.getString(_kCustom) ?? '';
      notifyListeners();
    } catch (_) {}
  }

  /// Picks a personality. For `custom`, [customText] is the user's instruction;
  /// choosing custom with an empty instruction falls back to the default voice.
  Future<void> select(String id, {String customText = ''}) async {
    _id = presets.any((e) => e.id == id) ? id : 'default';
    if (_id == 'custom') _custom = customText.trim();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kId, _id);
      await p.setString(_kCustom, _custom);
    } catch (_) {}
    notifyListeners();
  }

  @visibleForTesting
  void resetForTest() {
    _id = 'default';
    _custom = '';
  }
}
