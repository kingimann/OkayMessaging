import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide Session;

import '../crypto/key_exchange.dart';
import '../crypto/notification_preview.dart';
import '../relay/relay_config.dart';
import 'preview_key_store.dart';
import 'push_service.dart';
import 'self_test.dart';
import 'session.dart';

/// "Check notification preview": sends this device a REAL test push through
/// the real pipeline (relay_service's sealing, push-send's relay, the
/// Notification Service Extension's decrypt) and reports the one thing the
/// extension's own silent-failure design can never say for itself — whether
/// the shared keychain it reads from was writable at all.
///
/// WHY THE KEYCHAIN CHECK IS SEPARATE FROM SENDING A PUSH. The extension
/// treats every failure the same way on purpose (a wrong banner is worse
/// than a vague one), so a locked screen that still says "New message"
/// could mean an old build, a stale server deployment, or a keychain the
/// extension can't reach — three different faults with one appearance, the
/// same problem [PushSelfTest] exists to untangle for APNs credentials.
/// [PreviewKeyStore.testWrite] answers the one of those three this app CAN
/// check: whether the shared keychain group is writable by this process
/// right now, bypassing [PreviewKeyStore]'s own `_unavailable` latch, which
/// remembers only the FIRST attempt of the whole app run and would report a
/// launch-time failure as still true minutes later even if it were transient.
///
/// **What this cannot prove.** A successful write from the main app process
/// does not guarantee the EXTENSION (a different process, its own keychain
/// view of the "same" group) can read it back — that half needs the real
/// push to actually arrive and be looked at. So the verdict always ends the
/// same way: check the lock screen for the test sentence.
class NotificationPreviewSelfTest {
  /// Injected so tests drive the send without a network.
  @visibleForTesting
  static Future<Map<String, dynamic>> Function(Map<String, dynamic> body)?
      debugSendProbe;

  /// What a locked screen should show if every step worked. Distinct enough
  /// that "New message" or a stale build's placeholder can't be mistaken
  /// for it.
  static const String testSentence =
      'If you can read this, the encrypted preview is working.';

  static Future<SelfTestReport> run() async {
    final me = Session.instance.user.value;
    final myDigits = PushService.digitsOf(me?.phone ?? '');
    final signedIn = me != null && myDigits.isNotEmpty;

    if (!RelayConfig.isEnabled || !signedIn) {
      final steps = stepsFor(
        relayEnabled: RelayConfig.isEnabled,
        signedIn: signedIn,
        hasIdentityKeys: false,
        keychainError: null,
        attempted: false,
        sent: false,
      );
      final verdict = verdictFor(
        relayEnabled: RelayConfig.isEnabled,
        signedIn: signedIn,
        hasIdentityKeys: false,
        keychainError: null,
        attempted: false,
        sent: false,
      );
      return SelfTestReport(
        title: 'Notification preview self-test',
        steps: steps,
        verdict: verdict.$1,
        faulty: verdict.$2,
      );
    }

    final myPub = SecureKeyExchange.instance.myPublicKey;
    final hasIdentityKeys = myPub != null;
    final keychainError = await PreviewKeyStore.instance.testWrite();

    var attempted = false;
    var sent = false;
    String? sendError;
    if (hasIdentityKeys) {
      final secret = SecureKeyExchange.instance.sharedSecretWith(myPub);
      if (secret != null) {
        await PreviewKeyStore.instance.remember(myDigits, myPub);
        final sealed =
            NotificationPreview.seal(NotificationPreview.keyFor(secret), testSentence);
        attempted = true;
        try {
          final res = await (debugSendProbe ?? _sendReal)({
            'toPhone': myDigits,
            'title': 'Notification test',
            'body': 'New message',
            'preview': sealed,
            'fromPhone': myDigits,
            'kind': 'msg',
          });
          sent = res['sent'] == true;
        } catch (e) {
          sendError = '$e';
        }
      }
    }

    final steps = stepsFor(
      relayEnabled: true,
      signedIn: true,
      hasIdentityKeys: hasIdentityKeys,
      keychainError: keychainError,
      attempted: attempted,
      sent: sent,
      sendError: sendError,
    );
    final verdict = verdictFor(
      relayEnabled: true,
      signedIn: true,
      hasIdentityKeys: hasIdentityKeys,
      keychainError: keychainError,
      attempted: attempted,
      sent: sent,
      sendError: sendError,
    );
    return SelfTestReport(
      title: 'Notification preview self-test',
      steps: steps,
      verdict: verdict.$1,
      faulty: verdict.$2,
    );
  }

  static Future<Map<String, dynamic>> _sendReal(
      Map<String, dynamic> body) async {
    final res = await Supabase.instance.client.functions
        .invoke('push-send', body: body)
        .timeout(const Duration(seconds: 20));
    if (res.status >= 400) {
      throw StateError('the server answered ${res.status}');
    }
    return res.data is Map ? Map<String, dynamic>.from(res.data) : {};
  }

  /// Every line of the report. Pure, so the interesting combinations are
  /// reachable from a test without a server or a real device.
  @visibleForTesting
  static List<DiagnosticStep> stepsFor({
    required bool relayEnabled,
    required bool signedIn,
    required bool hasIdentityKeys,
    required String? keychainError,
    required bool attempted,
    required bool sent,
    String? sendError,
  }) {
    final steps = <DiagnosticStep>[
      relayEnabled
          ? const DiagnosticStep(
              'Server', 'A Supabase project is configured.', CheckState.pass)
          : const DiagnosticStep(
              'Server',
              'No Supabase project is configured in this build, so there is '
                  'nothing to send a test push through.',
              CheckState.fail),
      signedIn
          ? const DiagnosticStep(
              'Signed in', 'This device has a session.', CheckState.pass)
          : const DiagnosticStep(
              'Signed in',
              'Not signed in, so there is no phone number to send a test '
                  'push to.',
              CheckState.fail),
    ];
    if (!relayEnabled || !signedIn) return steps;

    steps.add(hasIdentityKeys
        ? const DiagnosticStep(
            'Identity keys', 'Present on this device.', CheckState.pass)
        : const DiagnosticStep(
            'Identity keys',
            'Not ready yet — reopen a chat first, then run this again.',
            CheckState.fail));

    steps.add(keychainError == null
        ? const DiagnosticStep(
            'Shared keychain',
            'Writable and readable by this app right now.',
            CheckState.pass)
        : DiagnosticStep(
            'Shared keychain',
            'Could not write to the shared keychain group: $keychainError',
            CheckState.fail));

    if (!attempted) {
      steps.add(const DiagnosticStep(
        'Test push',
        'Not sent — identity keys have to be ready first.',
        CheckState.unknown,
      ));
      return steps;
    }

    steps.add(sent
        ? const DiagnosticStep(
            'Test push',
            'Sent. Check this device\'s lock screen or Notification Center '
                'now.',
            CheckState.pass)
        : DiagnosticStep(
            'Test push',
            sendError == null
                ? 'The server did not confirm delivery.'
                : 'Failed: $sendError',
            CheckState.fail));
    return steps;
  }

  /// The one sentence worth acting on, and whether it names a fault.
  @visibleForTesting
  static (String, bool) verdictFor({
    required bool relayEnabled,
    required bool signedIn,
    required bool hasIdentityKeys,
    required String? keychainError,
    required bool attempted,
    required bool sent,
    String? sendError,
  }) {
    if (!relayEnabled) {
      return (
        'This build has no Supabase project, so there is no server to send '
            'a test push. Nothing here can be checked.',
        true
      );
    }
    if (!signedIn) {
      return ('Sign in first — there is no phone number to test with.', true);
    }
    if (!hasIdentityKeys) {
      return (
        'This device has not generated its identity keys yet. Open any '
            'chat, then run this again.',
        true
      );
    }
    if (keychainError != null) {
      return (
        'The shared keychain group between this app and the Notification '
            'Service Extension is not writable from here right now '
            '($keychainError). Without it the extension has nothing to '
            'decrypt with, no matter what the server sends — this is a '
            'provisioning fault, not something a setting on this phone can '
            'fix. If this is errSecMissingEntitlement (-34018), see '
            'CLAUDE.md: it was already root-caused once (an unresolved '
            '"\$(AppIdentifierPrefix)" reaching compiled code instead of an '
            'App ID capability), so check the fix actually reached this '
            'build before assuming it is a new fault. A test push was still '
            'sent below, but expect it to show the plain fallback.',
        true
      );
    }
    if (!attempted) {
      return (
        'Could not derive a key to test with — try again in a moment.',
        true
      );
    }
    if (!sent) {
      return (
        'The test push could not be sent'
            '${sendError == null ? '' : ': $sendError'}. Check push setup '
            'first — this test rides the same push-send function.',
        true
      );
    }
    return (
      'Everything this app can check from here passed, and a real test '
          'push was sent to this device with the sentence: '
          '"$testSentence". Check the lock screen or Notification Center '
          'now — if it shows that sentence, the encrypted preview works '
          'end to end. If it still shows a generic alert despite every '
          'check above passing, the fault is on the EXTENSION\'s side of '
          'the shared keychain rather than the app\'s — check that both '
          'targets sign with the same team in Xcode.',
      false
    );
  }
}
