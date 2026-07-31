import 'package:flutter/material.dart';

import '../payments/connect_webview.dart';
import '../payments/payment_service.dart';
import '../theme/app_theme.dart';
import 'in_app_web_screen.dart';

/// How a hosted Stripe page can be shown here.
///
/// THE BLANK SCREEN. On the web build there is no WebView — ConnectWebView is a
/// stub that returns an empty box — so handing it a URL rendered *nothing*: an
/// app bar over blank space, with no error, no spinner and no way forward. It
/// went unnoticed because the web build used to reach Stripe's page by
/// navigating the tab and never came through this screen at all; going to the
/// hosted flow first is what routed it here.
enum HostedPresentation {
  /// Inside this app's own WebView. No browser, no popup.
  inThisScreen,

  /// There is no WebView to host it, which on the web build means the tab this
  /// already is. Offered as a button rather than done silently, so navigating
  /// away is something the person chose.
  needsThisTab,
}

/// Pure so both branches are tested; a platform check inside a build method is
/// a branch no test on one platform can reach.
HostedPresentation hostedPresentationFor({required bool webViewSupported}) =>
    webViewSupported
        ? HostedPresentation.inThisScreen
        : HostedPresentation.needsThisTab;

/// Whether to go straight to Stripe's hosted onboarding instead of trying the
/// embedded component first.
///
/// MEASURED, NOT GUESSED. Setting up payments works in the web build and fails
/// in the app, and the difference between those two is not the platform: the
/// web build has no WebView, so it has always used the hosted flow, while the
/// app uses the embedded component. So what is broken is the embedded path,
/// and the two candidates are both invisible from here — the app's publishable
/// key and the server's secret key belonging to different Stripe accounts, or
/// WKWebView refusing the cross-site iframe the component runs in. Wallet →
/// Check payments setup settles which.
///
/// Either way, leading with a path that has never once worked costs a spinner,
/// a failure and a wait before landing where this goes anyway. The hosted flow
/// still runs inside the app's own WebView — no browser, no popup — and Stripe
/// still collects the identity and banking details directly.
///
/// Flip this off with --dart-define=PREFER_EMBEDDED_CONNECT=true to try the
/// embedded component again once the self-test says which cause it was.
const bool preferHostedOnboarding = !bool.fromEnvironment(
  'PREFER_EMBEDDED_CONNECT',
  defaultValue: false,
);

/// Whether a failure from the embedded page should quietly become Stripe's
/// hosted flow instead of an error screen.
///
/// Three conditions, and each one is there for a reason worth keeping:
///
/// * [rendered] — once the component has painted, Stripe authenticated and the
///   user may be part-way through its forms. Swapping the page out then would
///   throw away what they typed.
/// * [alreadyFellBack] — once per screen. A hosted page that fails must not
///   restart the cycle.
/// * [onHosted] — the hosted page's own failures are its own.
bool shouldFallBackToHosted({
  required bool rendered,
  required bool alreadyFellBack,
  required bool onHosted,
}) =>
    !rendered && !alreadyFellBack && !onHosted;

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

  late SecretDispenser _dispenser = SecretDispenser(() async =>
      (await PaymentService.instance.connectSession()).clientSecret);

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

  /// Whether the embedded flow has already been given up on once. The fallback
  /// happens by itself, but only once per screen — a hosted page that fails
  /// must not restart the cycle.
  bool _fellBack = false;

  /// Whether the embedded component ever authenticated. A failure before it
  /// paints is worth stepping around; one after it painted means the user was
  /// part-way through Stripe's forms, and yanking the page out from under
  /// them would lose what they typed.
  bool _pageRendered = false;

  Future<void> _useHosted() async {
    setState(() => _loadingHosted = true);
    await _fetchHosted();
  }

  /// The fetch itself, without the leading setState — initState cannot call
  /// setState, because that would mark this element dirty during its parent's
  /// build. The flag is set directly there instead, so the first frame is
  /// already the spinner.
  Future<void> _fetchHosted() async {
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
        // Both routes are gone, so the embedded flow's reason matters now:
        // it is the one that names which Stripe key is wrong, and dropping it
        // would leave only "Stripe did not return a setup link".
        final first = _fallbackReason;
        _pageError = first == null
            ? _reasonFor(e)
            : '${_reasonFor(e)}\n\nThe in-app form failed first: $first';
      });
    }
  }

  @override
  void initState() {
    super.initState();
    if (preferHostedOnboarding) {
      // Straight to the flow that works. No session is minted at all, so the
      // publishable key and the Account Session — the two things the embedded
      // component needs and the hosted flow does not — never come into it.
      _loadingHosted = true;
      _fetchHosted();
      return;
    }
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
    // embedded flow; 'submitted' is the hosted flow reaching its return URL.
    // Either way the wallet should re-read its status.
    if (event == 'exit' || event == 'submitted') {
      Navigator.of(context).pop(true);
      return;
    }
    // The component painted, so Stripe authenticated the session.
    if (event == 'ready') {
      _pageRendered = true;
      return;
    }
    const prefix = 'error:';
    if (event.startsWith(prefix)) {
      final message = event.substring(prefix.length);
      // The embedded component failed before it ever rendered.
      //
      // Everything that causes that lives on the server — the two Stripe keys
      // being in different modes or belonging to different accounts, embedded
      // components switched off — and none of it is anything the person
      // holding the phone can do. The hosted flow needs no publishable key
      // and no Account Session, so it is untouched by all of it, and it runs
      // in this same WebView: no browser, no popup.
      //
      // So take it, rather than showing an error with a button that does this
      // anyway. The diagnosis still reaches the screen if the fallback
      // itself fails, which is when somebody actually needs it.
      if (shouldFallBackToHosted(
          rendered: _pageRendered,
          alreadyFellBack: _fellBack,
          onHosted: _hostedUrl != null)) {
        _fellBack = true;
        _fallbackReason = message;
        _useHosted();
        return;
      }
      setState(() => _pageError = message);
    }
  }

  /// Why the embedded flow was abandoned. Shown only if the hosted flow fails
  /// too — on its own it is not a problem the user has to hear about.
  String? _fallbackReason;

  void _retry() {
    if (preferHostedOnboarding && _hostedUrl == null) {
      setState(() {
        _attempt++;
        _pageError = null;
      });
      _useHosted();
      return;
    }
    setState(() {
      _attempt++;
      _pageError = null;
      _session = PaymentService.instance.connectSession();
      // A fresh page, so a fresh dispenser — but the old secrets stay spent
      // either way, because each `next()` mints rather than replays.
      _dispenser = SecretDispenser(() async =>
          (await PaymentService.instance.connectSession()).clientSecret);
    });
  }

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
          // Only worth offering when the embedded component is what is on
          // screen. When this build goes to the hosted flow first, this button
          // would just re-fetch what is already loading.
          if (_hostedUrl == null && !preferHostedOnboarding)
            TextButton(
              onPressed: _loadingHosted ? null : _useHosted,
              child: const Text('Trouble?'),
            ),
        ],
      ),
      // Fetching the hosted URL used to leave the failed embedded component on
      // screen with no spinner, because _loadingHosted only greyed out the
      // button. Tapping "Trouble?" therefore looked like it did nothing, or
      // like the same broken screen was loading forever.
      body: _loadingHosted
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Opening Stripe\'s own setup page…'),
                ],
              ),
            )
          : _hostedUrl != null
              ? hostedPresentationFor(
                          webViewSupported: ConnectWebView.isSupported) ==
                      HostedPresentation.needsThisTab
                  ? _openHere(_hostedUrl!)
                  : KeyedSubtree(
                      key: ValueKey('hosted-$_attempt'),
                      child: ConnectWebView.build(
                        url: _hostedUrl!,
                        // Stripe's own page — nothing of ours to hand it.
                        clientSecret: '',
                        publishableKey: '',
                        dark: dark,
                        accent: AppColors.accentOn(context),
                        onEvent: _onEvent,
                        // Stripe ends the hosted flow by navigating to return_url,
                        // which serves this app's own website — so catch it and come
                        // back to the app instead of rendering the site in here.
                        completionUrlPrefix: PaymentService.returnUrl,
                      ),
                    )
              : _pageError != null
                  ? _problem(context, _pageError!)
                  : FutureBuilder<ConnectSession>(
                      future: _session,
                      builder: (context, snap) {
                        if (snap.connectionState != ConnectionState.done) {
                          return const Center(
                              child: CircularProgressIndicator());
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
                            platformAccount: session.platformAccount,
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

  /// No WebView to put Stripe's page in, so say so and let the person decide
  /// to leave. Only reachable on the web build; the app has a WebView.
  Widget _openHere(String url) => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.open_in_new, size: 40),
              const SizedBox(height: 14),
              const Text(
                'This part of setup runs on Stripe\'s own page, and a browser '
                'tab cannot show it inside the app.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 18),
              FilledButton(
                onPressed: () =>
                    InAppWebScreen.open(context, url, title: 'Stripe'),
                child: const Text('Continue on Stripe'),
              ),
              const SizedBox(height: 8),
              Text('You will come back here when it is done.',
                  style:
                      TextStyle(fontSize: 12.5, color: AppColors.subtle(context))),
            ],
          ),
        ),
      );

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
    if (text.contains('stripe_account_session_failed')) {
      // Stripe's own reason, already carrying the hint the function added.
      return 'Stripe wouldn\'t start the setup form.\n\n'
          '${text.replaceFirst('PaymentException: ', '')}';
    }
    if (text.contains('no_onboarding_url')) {
      return 'Stripe did not return a setup link.\n\n'
          '(payments-onboard answered without a url — check '
          'STRIPE_SECRET_KEY and that Connect is enabled)';
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
                  style:
                      TextStyle(color: AppColors.subtle(context), fontSize: 13.5)),
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
