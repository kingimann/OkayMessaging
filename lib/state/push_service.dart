import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide Session;

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

  Future<void> register() async {
    if (_started || kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
      return;
    }
    if (!RelayConfig.isEnabled) return;
    _started = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'token') await _upload(call.arguments as String?);
    });
    try {
      await _channel.invokeMethod<bool>('register');
    } catch (_) {
      // Simulator or channel unavailable — push simply stays off.
    }
  }

  Future<void> _upload(String? token) async {
    final me = Session.instance.user.value;
    if (token == null || token.isEmpty || me == null) return;
    try {
      await Supabase.instance.client.from('push_tokens').upsert({
        'phone': me.phone.replaceAll(RegExp(r'\D'), ''),
        'token': token,
        'platform': 'ios',
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (_) {}
  }

  /// Fire-and-forget: asks the server to push a wake-up alert to [toPhone].
  /// Kept content-minimal (sender name + generic body) by design.
  Future<void> notify(String toPhone, {required String title, String? body}) async {
    if (!RelayConfig.isEnabled) return;
    try {
      await Supabase.instance.client.functions.invoke('push-send', body: {
        'toPhone': toPhone,
        'title': title,
        'body': body ?? 'New message',
      });
    } catch (_) {}
  }
}
