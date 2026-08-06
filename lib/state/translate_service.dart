import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// On-device translation of message and post text.
///
/// ON THE DEVICE, ALWAYS. This runs against Apple's Translation framework
/// through `okay/translate`; the text is translated in the app's own process
/// and goes nowhere else. That is the whole point here — message bodies are
/// end-to-end encrypted before they leave the device, so a cloud translator
/// would mean decrypting somebody's chat somewhere it can be read, which is
/// the one thing this app promises never happens. There is no network path in
/// this file and there must never be one — not even for the public feed, which
/// could use one but doesn't, so a single Translate button behaves the same
/// everywhere and nobody has to reason about which surface is safe.
///
/// Apple's framework downloads the language pack on first use (with the
/// system's own consent prompt) and translates offline after that.
class TranslateService extends ChangeNotifier {
  TranslateService._();
  static final TranslateService instance = TranslateService._();

  static const MethodChannel _channel = MethodChannel('okay/translate');
  static const _prefKey = 'translate_target_v1';

  /// The languages offered as a translation target. Code → display name; the
  /// code is what the platform framework speaks (BCP-47 base). Kept short and
  /// common rather than exhaustive — the framework supports more, but a wall
  /// of a hundred languages is worse to pick from than a useful dozen.
  static const Map<String, String> languages = {
    'en': 'English',
    'es': 'Spanish',
    'fr': 'French',
    'de': 'German',
    'it': 'Italian',
    'pt': 'Portuguese',
    'nl': 'Dutch',
    'ru': 'Russian',
    'ar': 'Arabic',
    'hi': 'Hindi',
    'zh': 'Chinese',
    'ja': 'Japanese',
    'ko': 'Korean',
    'tr': 'Turkish',
    'pl': 'Polish',
    'uk': 'Ukrainian',
  };

  String _target = '';

  /// The language to translate INTO. Defaults to the device's language when
  /// unset, falling back to English when that isn't one we offer.
  String get target {
    if (_target.isNotEmpty) return _target;
    final device =
        PlatformDispatcher.instance.locale.languageCode.toLowerCase();
    return languages.containsKey(device) ? device : 'en';
  }

  String targetName([String? code]) =>
      languages[code ?? target] ?? (code ?? target);

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_prefKey) ?? '';
      if (languages.containsKey(saved)) {
        _target = saved;
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> setTarget(String code) async {
    if (!languages.containsKey(code) || code == _target) return;
    _target = code;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, code);
    } catch (_) {}
  }

  bool? _available;

  /// Whether this device can translate at all — Apple's framework is iOS 17.4+,
  /// so false on the web build, on Android, and on older iPhones. Every caller
  /// must treat "no" as the normal case, not an error.
  Future<bool> get available async {
    if (debugAvailableOverride != null) return debugAvailableOverride!;
    if (_available != null) return _available!;
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
      return _available = false;
    }
    try {
      final ok = await _channel.invokeMethod<bool>('available');
      return _available = ok ?? false;
    } on PlatformException {
      return _available = false;
    } on MissingPluginException {
      return _available = false;
    }
  }

  /// Cache keyed by "target|text" — a message re-translated (scroll away and
  /// back) shouldn't hit the framework twice, and the answer can't change.
  final Map<String, String> _cache = {};

  /// Translates [text] into [into] (defaults to [target]). Returns the
  /// translated string, or null when the device can't translate, the text is
  /// blank, or the framework declined. Null is a normal answer the UI shows as
  /// "couldn't translate", never a crash.
  Future<String?> translate(String text, {String? into}) async {
    final t = text.trim();
    if (t.isEmpty) return null;
    final dest = into ?? target;
    final key = '$dest|$t';
    final hit = _cache[key];
    if (hit != null) return hit;
    if (!await available) return null;
    try {
      final override = debugTranslateOverride;
      final out = override != null
          ? await override(t, dest)
          : await _channel.invokeMethod<String>('translate', {
              'text': t,
              'target': dest,
            });
      if (out == null || out.trim().isEmpty) return null;
      _cache[key] = out;
      return out;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Test hooks — the real path needs an iPhone on iOS 17.4+, which no test
  /// runner is.
  @visibleForTesting
  static bool? debugAvailableOverride;

  @visibleForTesting
  static Future<String?> Function(String text, String target)?
      debugTranslateOverride;

  @visibleForTesting
  void resetForTest() {
    _available = null;
    _target = '';
    _cache.clear();
    debugAvailableOverride = null;
    debugTranslateOverride = null;
  }
}
