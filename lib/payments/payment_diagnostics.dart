import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../relay/relay_config.dart';
import '../state/session.dart';
import 'payment_service.dart';

/// One line of the payments self-test. Named CheckState rather than StepState
/// because Material already has a StepState and the clash is silent until it
/// is not.
enum CheckState { pass, fail, unknown }

class DiagnosticStep {
  final String title;

  /// What was found. Shown verbatim, so it must never contain a secret.
  final String detail;
  final CheckState state;

  const DiagnosticStep(this.title, this.detail, this.state);
}

/// What the self-test found, and the one sentence worth acting on.
class PaymentDiagnostics {
  final List<DiagnosticStep> steps;

  /// The fix, or a statement that nothing looks wrong from here.
  final String verdict;

  /// Whether [verdict] names a fault rather than a clean result.
  final bool faulty;

  const PaymentDiagnostics(
      {required this.steps, required this.verdict, required this.faulty});

  /// A block of text somebody can paste into a message. No secret keys exist
  /// on a client, and the publishable key is masked anyway, so this is safe to
  /// send — but it is written to be read, not parsed.
  String get report => [
        'Payments self-test',
        for (final s in steps)
          '${switch (s.state) {
            CheckState.pass => '[ok]  ',
            CheckState.fail => '[FAIL]',
            CheckState.unknown => '[ ? ] ',
          }} ${s.title}: ${s.detail}',
        '',
        verdict,
      ].join('\n');
}

/// Runs the payments chain and says which link is broken.
///
/// WHY THIS EXISTS. Setting up payments failed repeatedly with Stripe's
/// "An error occurred while authenticating your account", which is Stripe's
/// wording for *this publishable key cannot authenticate this session* and
/// says nothing about which of the two keys is wrong. Diagnosing it took
/// several rounds of asking somebody to check a dashboard, because the missing
/// fact — which Stripe account the server's secret key belongs to — is only
/// knowable from the server, and the app was never asking.
///
/// So it asks. Every step reports what it found, and the verdict is computed by
/// [verdictFor], which is pure and tested.
class PaymentsSelfTest {
  /// Injected so tests drive the whole thing without a network.
  @visibleForTesting
  static Future<Map<String, dynamic>> Function()? debugSessionProbe;

  @visibleForTesting
  static Future<StripeKeyFacts> Function(String key)? debugKeyProbe;

  /// A test binary carries no --dart-define, so the key has to come from
  /// somewhere for the interesting cases to be reachable at all.
  @visibleForTesting
  static String? debugAppKey;

  static Future<PaymentDiagnostics> run() async {
    final steps = <DiagnosticStep>[];

    steps.add(RelayConfig.isEnabled
        ? const DiagnosticStep(
            'Server', 'A Supabase project is configured.', CheckState.pass)
        : const DiagnosticStep('Server',
            'No Supabase project is configured in this build.', CheckState.fail));

    final signedIn = Session.instance.user.value != null;
    steps.add(signedIn
        ? const DiagnosticStep(
            'Signed in', 'This device has a session.', CheckState.pass)
        : const DiagnosticStep(
            'Signed in',
            'Not signed in, so the server cannot tell who is asking.',
            CheckState.fail));

    // --- the app's own key -------------------------------------------------
    final appKey = debugAppKey ?? PaymentService.publishableKey;
    final appMode = modeOfPublishableKey(appKey);
    StripeKeyFacts? keyFacts;
    if (appKey.isEmpty) {
      steps.add(const DiagnosticStep('App key',
          'This build has no Stripe publishable key.', CheckState.fail));
    } else {
      keyFacts = await (debugKeyProbe ?? _probeKey)(appKey);
      steps.add(DiagnosticStep(
        'App key',
        keyFacts.recognised
            ? '${maskKey(appKey)} — $appMode mode'
                '${keyFacts.account.isEmpty ? '' : ', account ${keyFacts.account}'}'
            : '${maskKey(appKey)} — Stripe does not recognise this key.',
        keyFacts.recognised ? CheckState.pass : CheckState.fail,
      ));
    }

    // --- what the server answers -------------------------------------------
    Map<String, dynamic>? session;
    String? sessionError;
    try {
      session = await (debugSessionProbe ?? _probeSession)();
    } catch (e) {
      sessionError = '$e';
    }
    if (sessionError != null) {
      steps.add(DiagnosticStep('Server session',
          _shortenError(sessionError), CheckState.fail));
    } else {
      final secret = (session?['clientSecret'] as String?) ?? '';
      steps.add(secret.isEmpty
          ? const DiagnosticStep('Server session',
              'The server answered without a session.', CheckState.fail)
          : const DiagnosticStep('Server session',
              'Stripe minted an Account Session.', CheckState.pass));

      final mode = session?['mode'] as String?;
      final platform = (session?['platformAccount'] as String?) ?? '';
      steps.add(mode == null
          ? const DiagnosticStep(
              'Server key',
              'This deployment is too old to say which mode or account its '
                  'secret key belongs to. Re-paste payments-account-session.',
              CheckState.unknown)
          : DiagnosticStep(
              'Server key',
              '$mode mode'
                  '${platform.isEmpty ? ' (account not reported)' : ', account $platform'}',
              CheckState.pass));
    }

    final verdict = verdictFor(
      appKeyMode: appMode,
      appKeyAccount: keyFacts?.account ?? '',
      appKeyRecognised: keyFacts?.recognised ?? (appKey.isEmpty ? false : true),
      appKeyPresent: appKey.isNotEmpty,
      serverMode: session?['mode'] as String?,
      serverAccount: (session?['platformAccount'] as String?) ?? '',
      serverError: sessionError,
      signedIn: signedIn,
    );
    return PaymentDiagnostics(
        steps: steps, verdict: verdict.$1, faulty: verdict.$2);
  }

  /// The whole point of the exercise: given both halves, say what is wrong.
  ///
  /// Pure, and ordered by how much a wrong answer would cost. A missing key
  /// beats a mode mismatch beats an account mismatch, because each earlier
  /// fault would produce the later symptom anyway.
  @visibleForTesting
  static (String, bool) verdictFor({
    required String appKeyMode,
    required String appKeyAccount,
    required bool appKeyRecognised,
    required bool appKeyPresent,
    required String? serverMode,
    required String serverAccount,
    required String? serverError,
    required bool signedIn,
  }) {
    if (!signedIn) {
      return ('Sign in first — the server cannot start a Stripe session for '
          'an unknown device.', true);
    }
    if (!appKeyPresent) {
      return ('This build has no Stripe publishable key. Set the '
          'STRIPE_PUBLISHABLE_KEY Edge Function secret to the pk_live_ key '
          'from the same Stripe account as STRIPE_SECRET_KEY, and the app '
          'will use that.', true);
    }
    if (!appKeyRecognised) {
      return ('Stripe does not recognise the publishable key this app uses. '
          'It has been rolled or deleted, so nothing can authenticate '
          'against it.', true);
    }
    if (serverError != null) {
      return ('The server could not start a Stripe session: '
          '${_shortenError(serverError)}', true);
    }
    if (serverMode != null && appKeyMode.isNotEmpty && serverMode != appKeyMode) {
      return ('The keys are in different modes. This app uses a $appKeyMode '
          'key; STRIPE_SECRET_KEY on the server is a $serverMode key. Set '
          'STRIPE_SECRET_KEY to an sk_${appKeyMode}_ key.', true);
    }
    if (appKeyAccount.isNotEmpty &&
        serverAccount.isNotEmpty &&
        appKeyAccount != serverAccount) {
      return ('The keys belong to different Stripe accounts. This app\'s key '
          'is from $appKeyAccount; STRIPE_SECRET_KEY belongs to '
          '$serverAccount. Set STRIPE_SECRET_KEY to an sk_${appKeyMode}_ key '
          'from $appKeyAccount — or set the STRIPE_PUBLISHABLE_KEY secret to '
          'the pk_${appKeyMode}_ key from $serverAccount.', true);
    }
    if (serverMode == null) {
      return ('Everything this app can see is in order. It cannot check the '
          'server\'s key, because that deployment is an older version — '
          're-paste payments-account-session and run this again.', false);
    }
    if (serverAccount.isEmpty || appKeyAccount.isEmpty) {
      return ('Both keys are in $appKeyMode mode. Whether they belong to the '
          'same Stripe account could not be established from here.', false);
    }
    return ('Both keys are $appKeyMode keys from $appKeyAccount. Nothing is '
        'wrong with the keys.', false);
  }

  /// 'live', 'test', or '' when it is not a publishable key at all.
  static String modeOfPublishableKey(String key) =>
      key.startsWith('pk_live_')
          ? 'live'
          : (key.startsWith('pk_test_') ? 'test' : '');

  /// Last four characters only. A publishable key is client-safe, but a report
  /// meant to be pasted into a message should not carry a whole key.
  static String maskKey(String key) =>
      key.length <= 4 ? key : '…${key.substring(key.length - 4)}';

  static Future<Map<String, dynamic>> _probeSession() async {
    final s = await PaymentService.instance.connectSessionRaw();
    return s;
  }

  /// Asks Stripe which account a publishable key belongs to.
  ///
  /// Posting a publishable key to /v1/tokens with no other parameter creates
  /// nothing — Stripe answers with a parameter error whose request_log_url
  /// names the account. Same endpoint Stripe.js uses, and nothing but the key
  /// is sent.
  static Future<StripeKeyFacts> _probeKey(String key) async {
    try {
      final r = await http
          .post(Uri.parse('https://api.stripe.com/v1/tokens'),
              headers: {'Content-Type': 'application/x-www-form-urlencoded'},
              body: 'key=${Uri.encodeQueryComponent(key)}')
          .timeout(const Duration(seconds: 15));
      final body = jsonDecode(r.body);
      final err = (body is Map ? body['error'] : null) as Map?;
      final message = '${err?['message'] ?? ''}';
      if (message.contains('Invalid API Key') ||
          err?['code'] == 'api_key_expired') {
        return const StripeKeyFacts(recognised: false, account: '');
      }
      final match =
          RegExp(r'acct_[A-Za-z0-9]+').firstMatch('${err?['request_log_url']}');
      return StripeKeyFacts(
          recognised: true, account: match?.group(0) ?? '');
    } catch (_) {
      // Unreachable is not the same as unrecognised.
      return const StripeKeyFacts(recognised: true, account: '');
    }
  }

  static String _shortenError(String raw) {
    final text = raw.replaceFirst('PaymentException: ', '');
    return text.length > 240 ? '${text.substring(0, 240)}…' : text;
  }
}

/// What Stripe says about a publishable key.
class StripeKeyFacts {
  final bool recognised;

  /// The Stripe account the key belongs to, or '' when Stripe didn't say.
  final String account;

  const StripeKeyFacts({required this.recognised, required this.account});
}
