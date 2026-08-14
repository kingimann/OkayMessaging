import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide Session;

import '../app_state.dart';
import '../relay/relay_config.dart';
import '../relay/relay_service.dart';
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

  /// The PushKit VoIP token — a SEPARATE token from the alert one, because
  /// Apple runs VoIP pushes through their own pipe. This is what lets an
  /// incoming call ring CallKit on the lock screen of a closed app.
  String? _voipToken;

  /// What iOS said when it REFUSED to issue a token — the failure that used
  /// to be invisible. "no valid 'aps-environment' entitlement" here means
  /// the build was signed without the Push capability, which only a new
  /// build can fix; the diagnostics screen reads this to say so.
  String? registrationError;

  /// Why the last token upload didn't stick, or null after a clean one.
  String? lastUploadError;

  /// Whether iOS has handed this process a device token. With this true and
  /// the server still reporting no row, the fault is the upload, not iOS.
  bool get tokenReceived => (_lastToken ?? '').isNotEmpty;

  Future<void> register() async {
    if (_started || kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
      return;
    }
    if (!RelayConfig.isEnabled) return;
    _started = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'token') {
        registrationError = null;
        await _upload(call.arguments as String?);
      }
      if (call.method == 'tokenError') {
        registrationError = '${call.arguments ?? 'unknown'}';
      }
      if (call.method == 'voipToken') {
        _voipToken = call.arguments as String?;
        await _upload(_lastToken);
      }
      // A background wake off a message push: drain the mailbox NOW, so
      // the message is in the chat before the person opens the app and the
      // sender's ticks advance to delivered.
      if (call.method == 'sync') {
        try {
          await RelayService.instance.fetchMailbox();
        } catch (_) {}
        return true;
      }
      return null;
    });
    AppState.privateNotifications.addListener(_onPrivateChanged);
    try {
      await _channel.invokeMethod<bool>('register');
    } catch (_) {
      // Simulator or channel unavailable — push simply stays off.
    }
  }

  void _onPrivateChanged() => _upload(_lastToken);

  /// Re-uploads the last known token for the CURRENT account — called after
  /// sign-in, because iOS handed the token over long before this account
  /// existed, and nothing else would ever re-attach it.
  Future<void> reupload() => _upload(_lastToken);

  /// Test hook: stands in for the native local-notification channel, which is
  /// a no-op off iOS. Lets a test see what a feed/community alert would raise.
  @visibleForTesting
  static void Function(String title, String body)? debugLocalNotify;

  /// Posts a notification from THIS device to itself — for things that
  /// happen over the radio with no server in the loop (an Okay Drop offer
  /// arriving while the app is in the background, or a feed/community alert
  /// the Alerts tab also shows). No-op off iOS and when the native side is
  /// older than this method.
  Future<void> localNotify({required String title, String? body}) async {
    final hook = debugLocalNotify;
    if (hook != null) {
      hook(title, body ?? '');
      return;
    }
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
    try {
      await _channel.invokeMethod<void>(
          'localNotify', {'title': title, 'body': body ?? ''});
    } catch (_) {}
  }

  /// Test hook for [localNotifyAt] / [cancelLocalNotify]: the scheduled
  /// notifications this device has asked the OS for, keyed by [id]. A
  /// cancelled one is removed, so a test can assert both directions.
  @visibleForTesting
  static Map<String, ({String title, String body, DateTime at})>?
      debugScheduled;

  /// Asks the OS to post a notification to this device at [at], later.
  ///
  /// Unlike [localNotify] this survives the app being closed — iOS holds the
  /// request itself, so nothing here has to still be running when it fires.
  /// That is the whole reason a meeting reminder uses it rather than the
  /// [Scheduler]'s timer, which by its own doc only delivers "while the app
  /// is running".
  ///
  /// [id] replaces any earlier request under the same id rather than
  /// stacking a second one, and is what [cancelLocalNotify] takes back. A
  /// time already past is dropped: iOS delivers a zero-or-negative trigger
  /// immediately, which reads as a bug rather than a reminder.
  Future<void> localNotifyAt({
    required String id,
    required String title,
    required DateTime at,
    String body = '',
  }) async {
    final seconds = at.difference(DateTime.now()).inSeconds;
    if (seconds <= 0) return;
    final hook = debugScheduled;
    if (hook != null) {
      hook[id] = (title: title, body: body, at: at);
      return;
    }
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
    try {
      await _channel.invokeMethod<void>('localNotifyAt', {
        'id': id,
        'title': title,
        'body': body,
        'seconds': seconds,
      });
    } catch (_) {}
  }

  /// Takes back a pending [localNotifyAt]. Harmless when there is nothing
  /// scheduled under [id] — which is the common case, since it is called
  /// whenever an RSVP moves off "going" whether or not one was ever set.
  Future<void> cancelLocalNotify(String id) async {
    final hook = debugScheduled;
    if (hook != null) {
      hook.remove(id);
      return;
    }
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
    try {
      await _channel.invokeMethod<void>('cancelLocalNotify', {'id': id});
    } catch (_) {}
  }

  /// Zeroes the app-icon badge and the server's count behind it. Called
  /// when the app comes to the foreground: whatever the badge was counting
  /// has been seen, and a badge that never clears is a badge people learn
  /// to ignore.
  Future<void> clearBadge() async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      try {
        await _channel.invokeMethod<void>('clearBadge');
      } catch (_) {}
    }
    final me = Session.instance.user.value;
    if (me == null || !RelayConfig.isEnabled) return;
    // Numberless rows reset through their register RPC on next launch; a
    // session-holding account resets its own row directly.
    if (Session.instance.isNumberless) return;
    try {
      await Supabase.instance.client
          .from('push_tokens')
          .update({'unseen': 0}).eq(
              'phone', me.phone.replaceAll(RegExp(r'\D'), ''));
    } catch (_) {}
  }

  /// Removes this device's token row on sign-out, so the account that just
  /// left stops buzzing this phone. Best-effort — sign-out never blocks on
  /// the network.
  Future<void> removeToken() async {
    final token = _lastToken;
    if (token == null || token.isEmpty) return;
    try {
      await Supabase.instance.client
          .from('push_tokens')
          .delete()
          .eq('token', token);
    } catch (_) {}
  }

  Future<void> _upload(String? token) async {
    final me = Session.instance.user.value;
    // Either token is enough of a reason to have a row: the VoIP one can
    // arrive first, and a device that can ring but not banner is still a
    // device worth ringing.
    if (me == null || ((token ?? '').isEmpty && (_voipToken ?? '').isEmpty)) {
      return;
    }
    if (token != null && token.isNotEmpty) _lastToken = token;
    token = _lastToken ?? '';
    // A numberless account has no session, so the RLS-guarded upsert below
    // can never work for it — its row goes through the definer RPC that
    // only ever opens account-code rows. Without this, a closed app on a
    // numberless account received nothing at all.
    if (Session.instance.isNumberless) {
      try {
        await Supabase.instance.client
            .rpc('register_numberless_push', params: {
          'code': me.phone.replaceAll(RegExp(r'\D'), ''),
          't': token,
          'is_private': AppState.privateNotifications.value,
          if ((_voipToken ?? '').isNotEmpty) 'vt': _voipToken,
        });
      } catch (_) {}
      return;
    }
    try {
      await Supabase.instance.client.from('push_tokens').upsert({
        'phone': me.phone.replaceAll(RegExp(r'\D'), ''),
        'token': token,
        'platform': 'ios',
        // The recipient's flag, enforced server-side: the push is composed
        // on the SENDER's device, and a preference protecting this lock
        // screen cannot depend on somebody else's settings.
        'private': AppState.privateNotifications.value,
        if ((_voipToken ?? '').isNotEmpty) 'voip_token': _voipToken,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });
      lastUploadError = null;
    } catch (e) {
      // Kept, not just swallowed: "iOS handed a token but the server has no
      // row" is undiagnosable without the reason the write failed.
      lastUploadError = '$e';
      return;
    }
    // One device, one owner: release any OTHER account's row still naming
    // this device's token (the table is keyed by phone, so a previous
    // account's row survives an account switch and its messages would
    // keep arriving on this lock screen). Best-effort — the row above
    // already exists, so a failure here is not an upload failure.
    try {
      await Supabase.instance.client
          .rpc('claim_push_token', params: {'t': token});
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
  Future<void> notify(String toPhone,
      {required String title,
      String? body,
      String kind = 'msg',
      String? callId,
      bool video = false,
      String preview = ''}) async {
    if (!RelayConfig.isEnabled) return;
    final me = Session.instance.user.value;
    try {
      await Supabase.instance.client.functions.invoke('push-send', body: {
        'toPhone': toPhone,
        'title': title,
        'body': body ?? 'New message',
        // The words, sealed on this device — see [NotificationPreview]. It
        // is what turns that "New message" above into what was actually
        // said, and it stays the FALLBACK: an older recipient build has no
        // extension to open this, so the plain body must still stand alone.
        if (preview.isNotEmpty) 'preview': preview,
        'fromPhone': digitsOf(me?.phone ?? ''),
        // kind 'call' + callId is what lets push-send choose the VoIP pipe:
        // a call should RING the lock screen of a closed app, not banner it.
        'kind': kind,
        if (callId != null) 'callId': callId,
        if (kind == 'call') 'video': video,
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
