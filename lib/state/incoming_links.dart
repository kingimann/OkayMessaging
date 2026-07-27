import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// Receives the `im:` URLs iOS sends when OkayMessenger is the user's
/// default messaging app (Settings → Apps → Default Apps → Messaging) and
/// they tap a message action on a contact or link.
///
/// Phone targets open (or create) the chat with that number. Email targets
/// are the one thing this app can't message, so they fall back to the
/// system's `sms:` handler, per Apple's guidance.
class IncomingLinks {
  IncomingLinks._();
  static final IncomingLinks instance = IncomingLinks._();

  static const _channel = MethodChannel('okay/links');
  bool _started = false;

  /// Extracts the phone target of an `im:` (or `sms:`) URL as it should be
  /// dialed, e.g. 'im:+1-555-012.3456' → '+15550123456'. Returns null for
  /// email targets, other schemes, or anything with no dialable number. Pure.
  static String? imPhone(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) return null;
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'im' && scheme != 'sms') return null;
    // The target rides in the path (im:+1555…) or, with slashes, the
    // authority (im://+1555…).
    var target = Uri.decodeComponent(
        uri.path.isNotEmpty ? uri.path : uri.authority);
    target = target.replaceAll('/', '').trim();
    if (target.isEmpty || target.contains('@')) return null;
    final plus = target.startsWith('+');
    final digits = target.replaceAll(RegExp(r'\D'), '');
    if (digits.length < 7) return null;
    return (plus ? '+' : '') + digits;
  }

  /// Whether the URL targets an email address (an iMessage-only contact).
  static bool isEmailTarget(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) return false;
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'im' && scheme != 'sms') return false;
    final target = uri.path.isNotEmpty ? uri.path : uri.authority;
    return Uri.decodeComponent(target).contains('@');
  }

  /// Starts listening. [onPhone] receives the normalized number of every
  /// message tap, including one that launched the app cold.
  Future<void> init({required void Function(String phone) onPhone}) async {
    if (_started || kIsWeb) return;
    _started = true;
    Future<void> handle(Object? raw) async {
      final url = raw as String?;
      if (url == null) return;
      final phone = imPhone(url);
      if (phone != null) {
        onPhone(phone);
      } else if (isEmailTarget(url)) {
        // Hand iMessage-only targets back to the system, as Apple suggests.
        final fallback = Uri.tryParse(url.replaceFirst('im:', 'sms:'));
        if (fallback != null) {
          try {
            await launchUrl(fallback);
          } catch (_) {}
        }
      }
    }

    _channel.setMethodCallHandler((call) async {
      if (call.method == 'link') await handle(call.arguments);
    });
    try {
      await handle(await _channel.invokeMethod<String>('getInitial'));
    } catch (_) {
      // No native side (web, tests): nothing buffered.
    }
  }

  @visibleForTesting
  void resetForTest() => _started = false;
}
