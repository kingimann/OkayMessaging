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

  /// The first session is already in hand when the page asks for one; only
  /// later requests need a fresh trip to Stripe.
  bool _servedFirst = false;

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

  /// Answers the page's request for an Account Session client secret.
  ///
  /// Stripe calls this again when a session expires and requires a *new* one
  /// each time; handing back the same secret authenticates once at best.
  Future<String> _secret() async {
    if (!_servedFirst) {
      _servedFirst = true;
      final first = await _session;
      if (first != null) return first.clientSecret;
    }
    return (await PaymentService.instance.connectSession()).clientSecret;
  }

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
        _servedFirst = false;
        _session = PaymentService.instance.connectSession();
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
