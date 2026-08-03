import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide Session;

import '../relay/relay_config.dart';
import 'push_service.dart';
import 'self_test.dart';
import 'session.dart';

/// What Apple said when asked to push to a device that does not exist.
class ApnsProbe {
  final String host;

  /// HTTP status, or 0 when Apple could not be reached at all.
  final int status;

  /// Apple's `reason` string — `BadDeviceToken`, `InvalidProviderToken`, and
  /// so on. Empty when there was no answer to read.
  final String reason;

  const ApnsProbe(
      {required this.host, required this.status, required this.reason});

  factory ApnsProbe.fromJson(Map<String, dynamic> j) => ApnsProbe(
        host: '${j['host'] ?? ''}',
        status: (j['status'] as num?)?.toInt() ?? 0,
        reason: '${j['reason'] ?? ''}',
      );

  /// The one answer that means everything above the device token was accepted:
  /// the auth key, the team, and the topic. Apple only gets as far as
  /// disliking the token once it has approved all three.
  bool get keyAccepted => reason == 'BadDeviceToken';
}

/// The push-send self-test, as the server reported it. Carries no secret —
/// only whether each one is set and what Apple made of them.
class PushCheck {
  final bool hasP8;
  final bool hasKeyId;
  final bool hasTeamId;

  /// APNS_BUNDLE_ID, or '' when it is unset and the function's own default is
  /// in use. Not a secret: it is `com.okaymessaging` and it is in the repo.
  final String bundleId;

  /// Whether the server sends to Apple's sandbox rather than production.
  final bool sandbox;

  /// Why APNS_P8 could not be turned into a signing key, or '' if it could.
  final String keyError;

  final ApnsProbe production;
  final ApnsProbe sandboxHost;

  /// Whether the *caller's* phone has ever uploaded a device token.
  final bool deviceRegistered;

  const PushCheck({
    required this.hasP8,
    required this.hasKeyId,
    required this.hasTeamId,
    required this.bundleId,
    required this.sandbox,
    required this.keyError,
    required this.production,
    required this.sandboxHost,
    required this.deviceRegistered,
  });

  /// The host the server actually uses, which is the only one whose verdict
  /// decides whether a real push arrives.
  ApnsProbe get active => sandbox ? sandboxHost : production;

  static Map<String, dynamic> _map(Object? v) =>
      v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

  /// Returns null for an answer that isn't a self-test at all — which is what
  /// a push-send deployment predating the check replies with.
  static PushCheck? fromJson(Object? raw) {
    final j = _map(raw);
    if (j['secrets'] is! Map) return null;
    final s = _map(j['secrets']);
    return PushCheck(
      hasP8: s['p8'] == true,
      hasKeyId: s['keyId'] == true,
      hasTeamId: s['teamId'] == true,
      bundleId: '${s['bundleId'] ?? ''}',
      sandbox: s['sandbox'] == true,
      keyError: '${j['keyError'] ?? ''}',
      production: ApnsProbe.fromJson(_map(j['production'])),
      sandboxHost: ApnsProbe.fromJson(_map(j['sandbox'])),
      deviceRegistered: _map(j['device'])['registered'] == true,
    );
  }
}

/// "Check push setup": says whether the five APNS_* secrets are right.
///
/// WHY THIS EXISTS. Every way of getting push wrong produces the same symptom
/// — nothing happens — and the five secrets are set in a dashboard that cannot
/// validate any of them. A wrong team id, a key rolled at Apple, a bundle id
/// the key has no access to and a `.p8` pasted with its header mangled are
/// four different faults with one appearance, and the sixth possibility is
/// that everything is right and iOS never granted permission on the phone.
///
/// So it asks Apple. The server signs a real provider token and offers a push
/// to a device token that belongs to nobody; Apple validates the key, the team
/// and the topic before it looks at the token, and names whichever it
/// disliked. Nothing is delivered to anyone either way.
class PushSelfTest {
  /// Injected so tests drive the whole thing without a network.
  @visibleForTesting
  static Future<Object?> Function()? debugCheckProbe;

  /// Sentinel for "the server refused this phone's session token, even
  /// after a refresh". The local session object existing means nothing to
  /// the server once its refresh token is dead — which is exactly the state
  /// a phone signed in long ago and left in a drawer ends up in.
  static const String kSessionExpired = 'session-expired';

  static Future<SelfTestReport> run() async {
    PushCheck? check;
    String? error;
    if (RelayConfig.isEnabled && Session.instance.user.value != null) {
      try {
        final raw = await (debugCheckProbe ?? _probe)();
        check = PushCheck.fromJson(raw);
        if (check == null) error = 'old-deployment';
      } catch (e) {
        error = isAuthFailure(e) ? kSessionExpired : '$e';
      }
    }
    final verdict = verdictFor(
      relayEnabled: RelayConfig.isEnabled,
      signedIn: Session.instance.user.value != null,
      releaseBuild: kReleaseMode,
      pushablePlatform: pushablePlatform,
      check: check,
      error: error,
      tokenReceived: PushService.instance.tokenReceived,
      registrationError: PushService.instance.registrationError,
      uploadError: PushService.instance.lastUploadError,
    );
    return SelfTestReport(
      title: 'Push self-test',
      steps: stepsFor(
        relayEnabled: RelayConfig.isEnabled,
        signedIn: Session.instance.user.value != null,
        releaseBuild: kReleaseMode,
        pushablePlatform: pushablePlatform,
        check: check,
        error: error,
        tokenReceived: PushService.instance.tokenReceived,
        registrationError: PushService.instance.registrationError,
        uploadError: PushService.instance.lastUploadError,
      ),
      verdict: verdict.$1,
      faulty: verdict.$2,
    );
  }

  /// Whether this build can receive a push at all. APNs is iOS-only here; the
  /// web build has no device token to register and never will.
  static bool get pushablePlatform =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  static Future<Object?> _probe() async {
    Future<Object?> ask() async {
      final res = await Supabase.instance.client.functions
          .invoke('push-send', body: {'what': 'check'}).timeout(
              // Two round trips to Apple happen inside; generous, but
              // bounded, because this is the screen somebody opens when
              // nothing works.
              const Duration(seconds: 30));
      if (res.status >= 400) {
        throw StateError('the server answered ${res.status}');
      }
      return res.data;
    }

    try {
      return await ask();
    } catch (e) {
      if (!isAuthFailure(e)) rethrow;
      // A stale access token the SDK failed to rotate is indistinguishable
      // from a sign-in that is dead server-side — until a refresh is tried.
      // One refresh, one retry; only a second refusal is conclusive.
      var refreshed = false;
      try {
        await Supabase.instance.client.auth.refreshSession();
        refreshed = true;
      } catch (_) {}
      if (!refreshed) rethrow; // the original 401 stands confirmed
      return await ask();
    }
  }

  /// Whether [e] is the server refusing the caller's session token. The
  /// functions client throws FunctionException for non-2xx answers; the
  /// string check covers the manual status path above.
  @visibleForTesting
  static bool isAuthFailure(Object e) {
    if (e is FunctionException) return e.status == 401;
    return '$e'.contains('401');
  }

  /// Every line of the report. Pure, so the interesting combinations are
  /// reachable from a test without a server or an Apple account.
  @visibleForTesting
  static List<DiagnosticStep> stepsFor({
    required bool relayEnabled,
    required bool signedIn,
    required bool releaseBuild,
    required bool pushablePlatform,
    required PushCheck? check,
    required String? error,
    bool tokenReceived = false,
    String? registrationError,
    String? uploadError,
  }) {
    final steps = <DiagnosticStep>[
      relayEnabled
          ? const DiagnosticStep(
              'Server', 'A Supabase project is configured.', CheckState.pass)
          : const DiagnosticStep(
              'Server',
              'No Supabase project is configured in this build, so there is '
                  'nothing to send a push.',
              CheckState.fail),
      // Holding a session locally and the server still accepting it are two
      // different facts, and saying "Signed in ✓" above "unauthorized ✗" was
      // this report contradicting itself.
      error == PushSelfTest.kSessionExpired
          ? const DiagnosticStep(
              'Signed in',
              'This phone holds a sign-in the server no longer accepts — '
                  'the session has expired. Sign out and sign back in.',
              CheckState.fail)
          : signedIn
              ? const DiagnosticStep(
                  'Signed in', 'This device has a session.', CheckState.pass)
              : const DiagnosticStep(
                  'Signed in',
                  'Not signed in, so the server cannot tell who is asking.',
                  CheckState.fail),
      pushablePlatform
          ? const DiagnosticStep('This device',
              'iOS — it can receive pushes.', CheckState.pass)
          : const DiagnosticStep(
              'This device',
              'Push is iOS-only in this app, so this build will never receive '
                  'one. The server checks below still apply.',
              CheckState.unknown),
    ];

    if (check == null) {
      steps.add(DiagnosticStep(
        'Push server',
        error == 'old-deployment'
            ? 'This deployment of push-send is too old to check itself. '
                'Re-paste it in Edge Functions and run this again.'
            : error == PushSelfTest.kSessionExpired
                ? 'Not asked — the sign-in has to be fixed first.'
                : error == null
                    ? 'Not asked — see above.'
                    : 'push-send could not be asked: ${_short(error)}',
        error == null || error == PushSelfTest.kSessionExpired
            ? CheckState.unknown
            : CheckState.fail,
      ));
      return steps;
    }

    steps.add(check.keyError.isNotEmpty
        ? DiagnosticStep('APNS_P8',
            'Set, but not readable as a key: ${_short(check.keyError)}',
            CheckState.fail)
        : check.hasP8
            ? const DiagnosticStep(
                'APNS_P8', 'Set, and it signs.', CheckState.pass)
            : const DiagnosticStep(
                'APNS_P8',
                'Not set. Paste the whole .p8 file, BEGIN/END lines included.',
                CheckState.fail));

    steps.add(DiagnosticStep(
      'APNS_KEY_ID / APNS_TEAM_ID',
      check.hasKeyId && check.hasTeamId
          ? 'Both set.'
          : !check.hasKeyId && !check.hasTeamId
              ? 'Neither is set.'
              : check.hasKeyId
                  ? 'APNS_TEAM_ID is not set.'
                  : 'APNS_KEY_ID is not set.',
      check.hasKeyId && check.hasTeamId ? CheckState.pass : CheckState.fail,
    ));

    steps.add(DiagnosticStep(
      'APNS_BUNDLE_ID',
      check.bundleId.isEmpty
          ? 'Not set, so pushes go to com.okaymessaging — which is this app, '
              'so nothing is broken.'
          : check.bundleId,
      CheckState.pass,
    ));

    final active = check.active;
    steps.add(DiagnosticStep(
      'Apple',
      _appleDetail(active),
      active.keyAccepted
          ? CheckState.pass
          : active.status == 0
              ? CheckState.unknown
              : CheckState.fail,
    ));

    steps.add(DiagnosticStep(
      'APNS_SANDBOX',
      check.sandbox
          ? 'true — pushes go to Apple\'s sandbox. That is right only for a '
              'build installed from Xcode.'
          : 'false — pushes go to Apple\'s production servers, which is what '
              'TestFlight and the App Store use.',
      releaseBuild == check.sandbox ? CheckState.fail : CheckState.pass,
    ));

    steps.add(DiagnosticStep(
      'This device\'s token',
      check.deviceRegistered
          ? 'Registered — the server knows where to send.'
          : !pushablePlatform
              ? 'None, because this build cannot register one.'
              : registrationError != null
                  ? _isEntitlementError(registrationError)
                      ? 'iOS refused to issue one: this build was signed '
                          'without the push entitlement. Only a new build '
                          'can fix that — no setting on this phone can.'
                      : 'iOS refused to issue one: '
                          '${_short(registrationError)}'
                  : tokenReceived
                      ? 'iOS handed this app a token, but uploading it to '
                          'the server failed'
                          '${uploadError == null ? '.' : ': ${_short(uploadError)}'}'
                      : 'iOS has not handed this app a token this launch. '
                          'Allow notifications in iOS Settings, then close '
                          'the app fully and reopen it.',
      check.deviceRegistered
          ? CheckState.pass
          : pushablePlatform
              ? CheckState.fail
              : CheckState.unknown,
    ));
    return steps;
  }

  /// Apple's wording for "the binary has no aps-environment entitlement" —
  /// the one registration failure with a definite cause and a definite fix
  /// (a rebuild with a push-capable provisioning profile).
  static bool _isEntitlementError(String e) =>
      e.contains('aps-environment') || e.contains('entitlement');

  static String _appleDetail(ApnsProbe p) {
    if (p.status == 0) {
      return 'Apple could not be reached from the server'
          '${p.reason.isEmpty ? '' : ': ${p.reason}'}.';
    }
    return switch (p.reason) {
      'BadDeviceToken' =>
        'Accepted the key, the team and the app — it only rejected the '
            'made-up device token, which is the answer being asked for.',
      'InvalidProviderToken' =>
        'Rejected the signing key. APNS_KEY_ID, APNS_TEAM_ID and APNS_P8 do '
            'not belong together, or the key has no access to this app.',
      'ExpiredProviderToken' =>
        'Rejected the signing key as expired — the server\'s clock is wrong.',
      'TopicDisallowed' =>
        'Rejected the app id. The key is valid but has no access to '
            'APNS_BUNDLE_ID.',
      'MissingTopic' => 'Got no app id at all.',
      _ => 'Answered ${p.status}${p.reason.isEmpty ? '' : ' ${p.reason}'}.',
    };
  }

  /// The one sentence worth acting on, and whether it names a fault.
  ///
  /// Ordered by how much a wrong answer would cost: each earlier fault would
  /// produce every later symptom anyway, so reporting the later one first
  /// would send somebody after the wrong thing.
  @visibleForTesting
  static (String, bool) verdictFor({
    required bool relayEnabled,
    required bool signedIn,
    required bool releaseBuild,
    required bool pushablePlatform,
    required PushCheck? check,
    required String? error,
    bool tokenReceived = false,
    String? registrationError,
    String? uploadError,
  }) {
    if (!relayEnabled) {
      return (
        'This build has no Supabase project, so there is no server to send '
            'a push. Nothing here can be checked.',
        true
      );
    }
    if (!signedIn) {
      return ('Sign in first — the server cannot check push for an unknown '
          'device.', true);
    }
    if (error == kSessionExpired) {
      return (
        'This phone\'s sign-in has expired on the server (a refresh was '
            'tried and refused), so it cannot ask about push — or receive '
            'one. Sign out in Settings and sign back in with the same '
            'number, then run this again.',
        true
      );
    }
    if (error == 'old-deployment') {
      return (
        'The deployed push-send predates this check. Paste the current one '
            'from docs/edge_functions_paste/push-send.ts into Edge Functions '
            'and run this again.',
        true
      );
    }
    if (check == null) {
      return ('push-send could not be asked: ${_short(error ?? 'no answer')}',
          true);
    }
    if (check.keyError.isNotEmpty) {
      return (
        'APNS_P8 is set but cannot be read as a signing key '
            '(${_short(check.keyError)}). Paste the .p8 file exactly as '
            'downloaded, including its BEGIN and END lines.',
        true
      );
    }
    if (!check.hasP8) {
      return (
        'APNS_P8 is not set. Create an APNs key at developer.apple.com under '
            'Keys, and paste the whole downloaded .p8 file as the secret.',
        true
      );
    }
    if (!check.hasKeyId || !check.hasTeamId) {
      final missing = [
        if (!check.hasKeyId) 'APNS_KEY_ID',
        if (!check.hasTeamId) 'APNS_TEAM_ID',
      ].join(' and ');
      return (
        '$missing not set. The key id is the 10 characters in the .p8 '
            'filename; the team id is in the top right of developer.apple.com.',
        true
      );
    }
    final active = check.active;
    if (active.status == 0) {
      return (
        'Apple could not be reached from the server, so the key could not be '
            'checked. Everything the server holds looks set — run this again.',
        false
      );
    }
    if (active.reason == 'InvalidProviderToken') {
      return (
        'Apple rejected the signing key. APNS_KEY_ID, APNS_TEAM_ID and '
            'APNS_P8 must be the same key: the id in the .p8 filename, the '
            'team that key belongs to, and that file\'s contents.',
        true
      );
    }
    if (active.reason == 'TopicDisallowed') {
      return (
        'The key is valid but has no access to ${check.bundleId.isEmpty ? 'com.okaymessaging' : check.bundleId}. '
            'Set APNS_BUNDLE_ID to this app\'s bundle id, and make sure the '
            'APNs key was created in the team that owns it.',
        true
      );
    }
    if (active.reason == 'ExpiredProviderToken') {
      return (
        'Apple called the signing token expired, which means the server\'s '
            'clock is off rather than a secret being wrong.',
        true
      );
    }
    if (!active.keyAccepted) {
      return (
        'Apple answered ${active.status} ${active.reason} — the key was not '
            'accepted, and this is not one of the failures with a known fix.',
        true
      );
    }
    // Everything the server holds is right. What is left is which Apple
    // environment it points at, and whether this phone ever asked iOS.
    if (releaseBuild && check.sandbox) {
      return (
        'The secrets are right, but APNS_SANDBOX is true and this build came '
            'from TestFlight or the App Store — both use Apple\'s production '
            'servers, so every push is being sent somewhere this device is '
            'not. Set APNS_SANDBOX to false.',
        true
      );
    }
    if (!releaseBuild && !check.sandbox && pushablePlatform) {
      return (
        'The secrets are right for a TestFlight or App Store build. This one '
            'was installed from Xcode, which registers with Apple\'s sandbox, '
            'so pushes will not reach *this* copy until APNS_SANDBOX is true.',
        false
      );
    }
    if (!pushablePlatform) {
      return (
        'Every APNs secret is right — Apple accepted the key, the team and '
            'the app. This build cannot receive a push itself, so try it from '
            'the iPhone build to check the rest.',
        false
      );
    }
    if (!check.deviceRegistered) {
      if (registrationError != null && _isEntitlementError(registrationError)) {
        return (
          'Every APNs secret is right, but iOS refused to issue this build '
              'a push token: it was signed without the push entitlement. '
              'That is baked into the binary — install a build made after '
              'the Push capability was enabled. No setting on this phone '
              'can fix it.',
          true
        );
      }
      if (registrationError != null) {
        return (
          'Every APNs secret is right, but iOS refused to issue a push '
              'token: ${_short(registrationError)}',
          true
        );
      }
      if (tokenReceived) {
        return (
          'Every APNs secret is right and iOS issued a token, but uploading '
              'it to the server failed'
              '${uploadError == null ? '' : ': ${_short(uploadError)}'}. '
              'Check the connection and reopen the app to retry.',
          true
        );
      }
      return (
        'Every APNs secret is right, but this device has never uploaded a '
            'token — so nothing can be sent to it. Allow notifications for '
            'the app in iOS Settings, then close the app fully and reopen '
            'it. If this stays red after that, the installed build predates '
            'the push setup — install a newer build.',
        true
      );
    }
    return (
      'Push is set up correctly. Apple accepted the key, the team and the '
          'app, and this device is registered to receive.',
      false
    );
  }

  static String _short(String raw) =>
      raw.length > 200 ? '${raw.substring(0, 200)}…' : raw;
}
