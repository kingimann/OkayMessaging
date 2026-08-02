import 'package:flutter/material.dart';

import '../payments/connect_webview.dart';
import '../payments/payment_service.dart';
import '../state/identity_verification.dart';
import '../theme/app_theme.dart';

/// The ID check, inside the app.
///
/// Stripe runs the whole thing — the document photos and the selfie go
/// straight to them and are never seen, uploaded, or stored by this app. All
/// we ever learn is whether it passed. What this screen does is host that
/// flow rather than hand the user to a browser.
///
/// Two ways in, both on this screen:
///
///  * **Stripe.js**, when the session came with a client secret: our own
///    `identity.html` runs `verifyIdentity` and matches the app's theme.
///  * **Stripe's hosted page**, otherwise: loaded straight into the same
///    WebView. This is the path that used to launch an external browser,
///    which happens whenever the deployed identity-start predates client
///    secrets — a server old enough to only return a URL should still not
///    throw the user out of the app. It is also where
///    [IdentityVerification.pageIsServed] sends a check that starts while our
///    own site is mid-deploy: Stripe's page cannot 404 the way a static file
///    of ours can.
class IdentityCheckScreen extends StatefulWidget {
  final IdentitySession session;
  const IdentityCheckScreen({super.key, required this.session});

  @override
  State<IdentityCheckScreen> createState() => _IdentityCheckScreenState();

  /// Whether [session] can run on this screen at all: it needs a WebView plus
  /// either a client secret (Stripe.js) or a hosted URL to load. Pure, so the
  /// caller can decide between here and the browser without guessing.
  static bool canHost(IdentitySession session) =>
      ConnectWebView.isSupported &&
      (session.clientSecret.isNotEmpty || session.hostedUrl.isNotEmpty);
}

class _IdentityCheckScreenState extends State<IdentityCheckScreen> {
  bool _done = false;

  void _onEvent(String event) {
    if (!mounted || _done) return;
    // 'submitted' means Stripe has the documents; the verdict arrives later by
    // webhook, so the caller re-reads it rather than trusting this screen.
    if (event == 'submitted' || event == 'exit') {
      _done = true;
      Navigator.of(context).pop(event == 'submitted');
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final key = widget.session.publishableKey.isNotEmpty
        ? widget.session.publishableKey
        : PaymentService.publishableKey;
    // Stripe.js needs a secret and a key; without either, Stripe's own hosted
    // page does the same job in the same WebView.
    final useStripeJs =
        widget.session.clientSecret.isNotEmpty && key.isNotEmpty;
    final hosted = widget.session.hostedUrl;
    final canHost = ConnectWebView.isSupported && (useStripeJs || hosted.isNotEmpty);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Verify your identity'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Cancel',
          onPressed: () => Navigator.of(context).pop(false),
        ),
      ),
      body: !canHost
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  'Verifying your identity needs the mobile app.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.subtle(context)),
                ),
              ),
            )
          : ConnectWebView.build(
              url: useStripeJs ? IdentityVerification.pageUrl : hosted,
              clientSecret: widget.session.clientSecret,
              publishableKey: key,
              dark: dark,
              accent: AppColors.accentOn(context),
              onEvent: _onEvent,
              // Document capture and the selfie need the camera.
              needsCamera: true,
              // Either mode can end by navigating to the return URL: the
              // hosted page always does, and Stripe.js redirects there too
              // when it decides a WebView can't host its modal. Unwatched,
              // that navigation would render this app's own website inside
              // the WebView instead of finishing the check.
              completionUrlPrefix: IdentityVerification.returnUrl,
            ),
    );
  }
}
