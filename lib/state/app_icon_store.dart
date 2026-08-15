import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/app_icon_option.dart';

/// Which home-screen icon this app is currently wearing.
///
/// **Nothing is persisted here, deliberately.** iOS remembers the choice
/// itself — `alternateIconName` survives launches, updates and reinstall from
/// a backup — so a saved copy on disk would be a second answer that could
/// disagree with the icon actually on the home screen. It would also raise a
/// question with no good answer: the icon belongs to the app on the phone,
/// not to whichever account is signed in, so an account switch must not
/// change it, and a device-scoped preference is just a worse cache of what
/// the OS already knows. Reading the platform is the whole store.
///
/// (Saying "on disk" rather than naming the preferences class is not
/// squeamishness: `account_wipe`'s guard scans `lib/state` for that name and
/// fails any file carrying it that the wiper does not handle. It errs on the
/// safe side by design — demo prose has tripped it twice — so the rule is to
/// reword the comment, never to loosen the guard.)
///
/// Everywhere that is not iOS, [available] is false and the picker says so
/// rather than offering a control that cannot work: there is no such thing as
/// changing a web page's home-screen icon from inside it.
class AppIconStore extends ChangeNotifier {
  AppIconStore._();
  static final AppIconStore instance = AppIconStore._();

  static const MethodChannel _channel = MethodChannel('okay/appicon');

  /// Test seam. A real device is the only place the channel answers, so every
  /// test drives the store through this instead — the same shape
  /// `SmartReplies` and the other platform-backed features use.
  @visibleForTesting
  static Future<Object?> Function(String method, Map<String, Object?> args)?
      debugChannelOverride;

  bool _available = false;
  String _current = '';
  bool _loaded = false;

  /// Whether this device can change its icon at all. False until [load] has
  /// answered, which is the safe way round: a picker that appears and then
  /// refuses is worse than one that appears a frame late.
  bool get available => _available;

  /// The option in use. The default when nothing is set, when the platform
  /// cannot answer, and when the name belongs to a variant this build has
  /// never heard of.
  AppIconOption get current => appIconFor(_current);

  bool get loaded => _loaded;

  Future<Object?> _invoke(String method, [Map<String, Object?>? args]) async {
    final override = debugChannelOverride;
    if (override != null) return override(method, args ?? const {});
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return null;
    try {
      return await _channel.invokeMethod<Object?>(method, args);
    } catch (_) {
      // A missing channel is an older build or another platform, not a fault
      // worth surfacing: it just means the icon cannot be changed here.
      return null;
    }
  }

  Future<void> load() async {
    _available = await _invoke('available') == true;
    if (_available) _current = (await _invoke('current') as String?) ?? '';
    _loaded = true;
    notifyListeners();
  }

  /// Asks iOS for [option]. Returns whether it actually happened — the caller
  /// says so rather than assuming, because a refusal here is silent on the
  /// home screen.
  ///
  /// The stored answer is only updated on success, so a failed change leaves
  /// the picker showing the icon really in use rather than the one that was
  /// tapped.
  Future<bool> select(AppIconOption option) async {
    if (!_available) return false;
    if (option.bundleName == _current) return true;
    final ok = await _invoke('set', {'name': option.bundleName}) == true;
    if (ok) {
      _current = option.bundleName;
      notifyListeners();
    }
    return ok;
  }

  @visibleForTesting
  void resetForTest() {
    _available = false;
    _current = '';
    _loaded = false;
  }
}
