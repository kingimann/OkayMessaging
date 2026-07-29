import 'package:flutter/material.dart';

import '../payments/connect_webview.dart';
import '../payments/payment_service.dart';
import '../theme/app_theme.dart';

/// Setting up payments, inside the app.
///
/// Stripe's Connect onboarding is hosted by Stripe — it has to be, because
/// identity documents and bank details must go straight to them and never
/// through this app. What this screen does is embed those forms rather than
/// hand the user off: no browser, no popup, the app's own app bar, and the
/// app's own colours passed through to Stripe's appearance API.
class ConnectOnboardingScreen extends StatefulWidget {
  const ConnectOnboardingScreen({super.key});

  @override
  State<ConnectOnboardingScreen> createState() =>
      _ConnectOnboardingScreenState();
}

class _ConnectOnboardingScreenState extends State<ConnectOnboardingScreen> {
  Future<ConnectSession>? _session;

  /// Whatever the embedded page reported going wrong. Stripe's own words —
  /// the alternative was a red box inside the component saying only "please
  /// try again", on a screen that then sat there loading.
  String? _pageError;

  /// Bumped on every retry so the WebView is rebuilt rather than reused. A
  /// StatefulWidget in the same slot keeps its State, so without this the
  /// second attempt would show the first attempt's dead page.
  int _attempt = 0;

  late SecretDispenser _dispenser = SecretDispenser(
      () async => (await PaymentService.instance.connectSession()).clientSecret);

  /// Stripe's own hosted onboarding, once someone asks for it.
  ///
  /// The embedded component runs in a cross-origin iframe, and there are
  /// things a WebView can refuse it that a browser would not. When it will
  /// not authenticate there is nothing this app can do about it from the
  /// outside — but the hosted flow is plain navigation with no iframe and no
  /// Account Session, so it sidesteps the whole question. It still runs in
  /// this screen's WebView: no browser, no popup.
  String? _hostedUrl;
  bool _loadingHosted = false;

  Future<void> _useHosted() async {
    setState(() => _loadingHosted = true);
    try {
      final url = await PaymentService.instance.onboardingUrl();
      if (!mounted) return;
      setState(() {
        _hostedUrl = url;
        _pageError = null;
        _loadingHosted = false;
        _attempt++;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingHosted = false;
        _pageError = _reasonFor(e);
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _session = PaymentService.instance.connectSession();
  }

  /// Answers the page's request for an Account Session client secret, minting
  /// a fresh one every time.
  ///
  /// Never re-serves the session created in initState, even on the first
  /// request. That looks like a free optimisation and is the bug it used to
  /// be: the page receives that secret up front as `clientSecret` and spends
  /// it on the first authentication, so by the time it asks the host it needs
  /// the *second* one. Handing the same secret back made Stripe reject it and
  /// paint "An error occurred while authenticating your account" over a
  /// component that had already rendered.
  Future<String> _secret() => _dispenser.next();

  void _onEvent(String event) {
    if (!mounted) return;
    // 'exit' is Stripe telling us the user finished or backed out of the
    // embedded flow. Either way the wallet should re-read its status.
    if (event == 'exit') {
      Navigator.of(context).pop(true);
      return;
    }
    const prefix = 'error:';
    if (event.startsWith(prefix)) {
      setState(() => _pageError = event.substring(prefix.length));
    }
  }

  void _retry() => setState(() {
        _attempt++;
        _pageError = null;
        _session = PaymentService.instance.connectSession();
        // A fresh page, so a fresh dispenser — but the old secrets stay spent
        // either way, because each `next()` mints rather than replays.
        _dispenser = SecretDispenser(() async =>
            (await PaymentService.instance.connectSession()).clientSecret);
      });

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Set up payments'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Cancel',
          // The hosted flow gives no completion signal back to the app, so
          // closing it has to be treated as "something may have changed" —
          // otherwise finishing setup leaves the wallet showing the old
          // status until the next launch.
          onPressed: () => Navigator.of(context).pop(_hostedUrl != null),
        ),
        actions: [
          if (_hostedUrl == null)
            TextButton(
              onPressed: _loadingHosted ? null : _useHosted,
              child: const Text('Trouble?'),
            ),
        ],
      ),
      body: _hostedUrl != null
          ? KeyedSubtree(
              key: ValueKey('hosted-$_attempt'),
              child: ConnectWebView.build(
                url: _hostedUrl!,
                // Stripe's own page — nothing of ours to hand it.
                clientSecret: '',
                publishableKey: '',
                dark: dark,
                accent: AppColors.accentOn(context),
                onEvent: _onEvent,
              ),
            )
          : _pageError != null
          ? _problem(context, _pageError!)
          : FutureBuilder<ConnectSession>(
              future: _session,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError || !ConnectWebView.isSupported) {
                  return _problem(context, _reasonFor(snap.error));
                }
                final session = snap.data!;
                return KeyedSubtree(
                  key: ValueKey(_attempt),
                  child: ConnectWebView.build(
                    url: session.pageUrl,
                    clientSecret: session.clientSecret,
                    publishableKey: session.publishableKey,
                    dark: dark,
                    accent: AppColors.accentOn(context),
                    onEvent: _onEvent,
                    onSecretRequest: _secret,
                  ),
                );
              },
            ),
    );
  }

  /// Why setup didn't start, in words that point at the actual cause.
  ///
  /// This used to say "check your connection" for everything, which sent
  /// people to look at their wifi when the real answer was a function that
  /// hadn't been deployed or a Stripe setting that wasn't switched on.
  String _reasonFor(Object? error) {
    if (!ConnectWebView.isSupported) {
      return 'Setting up payments needs the mobile app.';
    }
    final text = error?.toString() ?? '';
    if (text.contains('NOT_FOUND') || text.contains('not found')) {
      return 'Payment setup isn\'t switched on for this app yet.\n\n'
          '(payments-account-session is not deployed)';
    }
    if (text.contains('unauthorized') || text.contains('401')) {
      return 'Sign in again to set up payments.';
    }
    // Two keys in different modes. Stripe reports this as an account
    // authentication failure, which sends people looking at their account.
    if (text.contains('key_mode_live_app_test_server')) {
      return 'Payments are in test mode on the server but this app is built '
          'with a live key.\n\n(set a live STRIPE_SECRET_KEY, or build with '
          'the matching pk_test_ key)';
    }
    if (text.contains('key_mode_test_app_live_server')) {
      return 'Payments are live on the server but this app is built with a '
          'test key.\n\n(build with the matching pk_live_ key)';
    }
    if (text.contains('no_publishable_key')) {
      return 'This build has no Stripe key.\n\n'
          '(set the STRIPE_PUBLISHABLE_KEY Edge Function secret)';
    }
    if (text.contains('stale_client_secret')) {
      return 'Stripe returned a session that had already been used, so it '
          'could not be authenticated. Try again.';
    }
    if (text.contains('no_client_secret')) {
      return 'The server did not return a Stripe session.\n\n'
          '(payments-account-session answered without a clientSecret)';
    }
    if (text.contains('TimeoutException')) {
      return 'Stripe did not answer. Check your connection and try again.';
    }
    if (text.isEmpty) {
      return 'Could not start setup. Check your connection and try again.';
    }
    // Anything else: show it. A vague message here costs more than an ugly
    // one, because nobody can act on "something went wrong".
    return 'Could not start setup.\n\n$text';
  }

  Widget _problem(BuildContext context, String message) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 44, color: Colors.grey.shade400),
              const SizedBox(height: 12),
              Text(message,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 13.5)),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _retry,
                child: const Text('Try again'),
              ),
              TextButton(
                onPressed: _loadingHosted ? null : _useHosted,
                child: const Text('Use Stripe\'s own page instead'),
              ),
            ],
          ),
        ),
      );
}

/// Hands Stripe a fresh Account Session client secret every time it asks.
///
/// A separate object because the rule it enforces is the whole reason
/// onboarding used to fail: an Account Session authenticates **once**, so a
/// secret that has already been given out is worthless, and re-serving one
/// makes Stripe report "An error occurred while authenticating your account" —
/// a message about the account, for a problem with the secret. The screen used
/// to hand back the session it created at start-up on the first request, not
/// realising the page had already spent that exact secret on its first
/// authentication.
///
/// Minting is delegated, so this is testable without Stripe or a WebView.
@visibleForTesting
class SecretDispenser {
  SecretDispenser(this._mint);

  final Future<String> Function() _mint;
  final Set<String> _spent = <String>{};

  /// How many secrets have been handed out.
  int get issued => _spent.length;

  /// A secret nobody has seen before. Throws [PaymentException] with
  /// 'no_client_secret' when the mint comes back empty, and
  /// 'stale_client_secret' when it repeats itself — better a named failure the
  /// screen can explain than a silent one Stripe blames on the user.
  Future<String> next() async {
    final secret = await _mint();
    if (secret.isEmpty) throw PaymentException('no_client_secret');
    if (!_spent.add(secret)) throw PaymentException('stale_client_secret');
    return secret;
  }
}
