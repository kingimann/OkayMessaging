import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide Session;

import '../app_state.dart';
import '../relay/relay_config.dart';
import 'session.dart';

/// Registers this iPhone for APNs push and uploads the device token to the
/// `push_tokens` table, so the push-send Edge Function can reach this device
/// when the app is closed. No-op on web/Android/tests.
class PushService {
  PushService._();
  static final PushService instance = PushService._();

  static const _channel = MethodChannel('okay/push');
  bool _started = false;

  /// The last APNs token iOS handed us, kept so flipping the private-
  /// notifications toggle can re-upsert the row without waiting for the next
  /// launch — the server enforces the flag, so a stale flag is a stale
  /// promise.
  String? _lastToken;

  Future<void> register() async {
    if (_started || kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
      return;
    }
    if (!RelayConfig.isEnabled) return;
    _started = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'token') await _upload(call.arguments as String?);
    });
    AppState.privateNotifications.addListener(_onPrivateChanged);
    try {
      await _channel.invokeMethod<bool>('register');
    } catch (_) {
      // Simulator or channel unavailable — push simply stays off.
    }
  }

  void _onPrivateChanged() => _upload(_lastToken);

  Future<void> _upload(String? token) async {
    final me = Session.instance.user.value;
    if (token == null || token.isEmpty || me == null) return;
    _lastToken = token;
    try {
      await Supabase.instance.client.from('push_tokens').upsert({
        'phone': me.phone.replaceAll(RegExp(r'\D'), ''),
        'token': token,
        'platform': 'ios',
        // The recipient's flag, enforced server-side: the push is composed
        // on the SENDER's device, and a preference protecting this lock
        // screen cannot depend on somebody else's settings.
        'private': AppState.privateNotifications.value,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (_) {}
  }

  /// Clears everything this app has sitting in Notification Center.
  ///
  /// Called when the app comes to the foreground and private notifications
  /// are on: the alert did its job — the phone buzzed, the app got opened —
  /// and a stack of "New message" rows in the pull-down history afterwards
  /// is a log of when people talked to you.
  Future<void> clearDelivered() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
    try {
      await _channel.invokeMethod<void>('clearDelivered');
    } catch (_) {
      // No native side (simulator, older binary) — alerts stay as they are.
    }
  }

  /// Fire-and-forget: asks the server to push a wake-up alert to [toPhone].
  /// Kept content-minimal (sender name + generic body) by design.
  ///
  /// The sender's own number rides along so a tap opens THAT conversation
  /// instead of the chat list. It reaches Apple, as the sender's name in the
  /// title already does — see the note in the Edge Function.
  Future<void> notify(String toPhone, {required String title, String? body}) async {
    if (!RelayConfig.isEnabled) return;
    final me = Session.instance.user.value;
    try {
      await Supabase.instance.client.functions.invoke('push-send', body: {
        'toPhone': toPhone,
        'title': title,
        'body': body ?? 'New message',
        'fromPhone': digitsOf(me?.phone ?? ''),
      });
    } catch (_) {}
  }

  /// Digits only, the form a push payload and an inbox are addressed by.
  static String digitsOf(String phone) => phone.replaceAll(RegExp(r'\D'), '');

  /// Tells iOS which conversation is on screen, so a push for it does not
  /// draw a banner over the message the app has already shown.
  ///
  /// Foreground alerts are suppressed entirely without this, which is why it
  /// exists: iOS shows nothing at all for a push that arrives while the app
  /// is open unless the app says otherwise, so somebody looking at the
  /// Servers tab got no hint that a message had come in.
  Future<void> setOpenChat(String? phone) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
    try {
      await _channel.invokeMethod<void>(
          'openChat', phone == null ? '' : digitsOf(phone));
    } catch (_) {
      // No native side (simulator, older binary) — banners stay as they are.
    }
  }
}
