import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// Receives the URLs iOS sends when OkayMessenger is the user's default
/// messaging or calling app (Settings → Apps → Default Apps): a message tap
/// arrives as `im:<number>`, a call tap as `tel:<number>`.
///
/// Phone targets open the matching chat or start a call. Email `im:` targets
/// are the one thing this app can't message, so they fall back to the
/// system's `sms:` handler; a call that can't be placed falls back to the
/// system's `telephony:` handler — both per Apple's guidance.
class IncomingLinks {
  IncomingLinks._();
  static final IncomingLinks instance = IncomingLinks._();

  static const _channel = MethodChannel('okay/links');
  bool _started = false;

  static const _messageSchemes = {'im', 'sms'};
  static const _callSchemes = {'tel', 'telprompt'};

  static String? _phoneOf(String url, Set<String> schemes) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !schemes.contains(uri.scheme.toLowerCase())) {
      return null;
    }
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

  /// The phone target of an `im:` (or `sms:`) URL as it should be dialed,
  /// e.g. 'im:+1-555-012.3456' → '+15550123456'. Null for email targets,
  /// other schemes, or anything with no dialable number. Pure.
  static String? imPhone(String url) => _phoneOf(url, _messageSchemes);

  /// The phone target of a `tel:` (or `telprompt:`) URL. Pure.
  static String? telPhone(String url) => _phoneOf(url, _callSchemes);

  /// The contact an `okaymsg://add?u=…&p=…&n=…` URL carries — the payload of
  /// the in-app QR code, which the iPhone camera hands to the app once the
  /// scheme is registered. Null for anything else. Pure.
  ///
  /// This parser is the reason scanning DOES something now: the QR encoded
  /// this URL from day one, but no scheme was registered, the scene delegate
  /// filtered it out, and nothing in Dart knew the shape — three gaps, one
  /// dead feature.
  static ({String phone, String name, String username})? addTarget(
      String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || uri.scheme.toLowerCase() != 'okaymsg') return null;
    final action =
        uri.host.isNotEmpty ? uri.host : uri.path.replaceAll('/', '');
    if (action != 'add') return null;
    final p = uri.queryParameters['p'] ?? '';
    final digits = p.replaceAll(RegExp(r'\D'), '');
    // Account codes and real numbers both ride here; either is an inbox.
    if (digits.length < 7) return null;
    return (
      phone: (p.trim().startsWith('+') ? '+' : '') + digits,
      name: (uri.queryParameters['n'] ?? '').trim(),
      username: (uri.queryParameters['u'] ?? '').trim(),
    );
  }

  /// Whether the URL targets an email address (an iMessage-only contact).
  static bool isEmailTarget(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null ||
        !_messageSchemes.contains(uri.scheme.toLowerCase())) {
      return false;
    }
    final target = uri.path.isNotEmpty ? uri.path : uri.authority;
    return Uri.decodeComponent(target).contains('@');
  }

  /// Hands a call to the system: cellular for voice, FaceTime for video.
  /// On iOS the `telephony:` scheme is the one Apple designates for default
  /// calling apps — opening plain tel: would just come back to us — with
  /// tel: as the fallback for anything older. Returns whether a handler
  /// opened.
  static Future<bool> systemDial(String number, {bool video = false}) async {
    Future<bool> open(String scheme) async {
      try {
        return await launchUrl(Uri.parse('$scheme:$number'));
      } catch (_) {
        return false;
      }
    }

    if (!kIsWeb && video && defaultTargetPlatform == TargetPlatform.iOS) {
      if (await open('facetime')) return true;
    }
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      if (await open('telephony')) return true;
    }
    return open('tel');
  }

  /// Hands a call the app can't place back to the system's cellular
  /// handling.
  static Future<void> systemCallFallback(String phone) async {
    await systemDial(phone);
  }

  /// Starts listening. [onPhone] receives the normalized number of every
  /// message tap and [onCall] of every call tap — including ones that
  /// launched the app cold.
  /// Whether [url] is a tap on this app's own notification (the native side
  /// stamps src=okay) — those must open in-app, never bounce to SMS.
  static bool isOwnPushTap(String url) =>
      Uri.tryParse(url.trim())?.queryParameters['src'] == 'okay';

  Future<void> init({
    required void Function(String phone) onPhone,
    required void Function(String phone) onCall,
    void Function(String phone)? onPushChat,
    void Function(({String phone, String name, String username}) target)?
        onAdd,
  }) async {
    if (_started || kIsWeb) return;
    _started = true;
    Future<void> handle(Object? raw) async {
      final url = raw as String?;
      if (url == null) return;
      final added = addTarget(url);
      if (added != null) {
        onAdd?.call(added);
        return;
      }
      final message = imPhone(url);
      if (message != null) {
        if (isOwnPushTap(url) && onPushChat != null) {
          onPushChat(message);
        } else {
          onPhone(message);
        }
        return;
      }
      final call = telPhone(url);
      if (call != null) {
        onCall(call);
        return;
      }
      if (isEmailTarget(url)) {
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
