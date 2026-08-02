import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Tells the app when somebody screenshots it.
///
/// **iOS cannot stop a screenshot.** There is no public API for it — the
/// private trick people reach for (a secure `UITextField` layered under the
/// view) is undocumented, breaks between releases, and is the sort of thing
/// App Review notices. What iOS does give is a notification *after* the fact,
/// and that is what this is.
///
/// So the protection is social rather than technical: the other person is
/// told. That is the same answer every messenger lands on, and it is worth
/// saying plainly in the UI rather than implying a block that does not exist.
///
/// No-op off iOS. Android has FLAG_SECURE and could genuinely block, but
/// there is no Android build here to wire it into.
class ScreenshotWatch {
  ScreenshotWatch._();
  static final ScreenshotWatch instance = ScreenshotWatch._();

  static const _channel = MethodChannel('okay/screenshot');

  /// Bumped each time the native side reports one. A screen listens while it
  /// is on top and ignores it otherwise, so a screenshot is attributed to
  /// whatever was actually being looked at.
  final ValueNotifier<int> taken = ValueNotifier<int>(0);

  bool _started = false;

  /// Lets a test drive the whole thing without a platform channel.
  @visibleForTesting
  void debugFire() => taken.value++;

  Future<void> start() async {
    if (_started || kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
      return;
    }
    _started = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'taken') taken.value++;
    });
    try {
      await _channel.invokeMethod<void>('watch');
    } catch (_) {
      // No native side (simulator, older binary): screenshots simply pass
      // unnoticed, which is what happened before this existed.
    }
  }
}
