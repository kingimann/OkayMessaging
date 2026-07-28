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

  @override
  void initState() {
    super.initState();
    _session = PaymentService.instance.connectSession();
  }

  void _onEvent(String event) {
    if (!mounted) return;
    // 'exit' is Stripe telling us the user finished or backed out of the
    // embedded flow. Either way the wallet should re-read its status.
    if (event == 'exit') Navigator.of(context).pop(true);
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
          onPressed: () => Navigator.of(context).pop(false),
        ),
      ),
      body: FutureBuilder<ConnectSession>(
        future: _session,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError || !ConnectWebView.isSupported) {
            return _problem(
              context,
              ConnectWebView.isSupported
                  ? 'Could not start setup. Check your connection and try '
                      'again.'
                  : 'Setting up payments needs the mobile app.',
            );
          }
          final session = snap.data!;
          return ConnectWebView.build(
            url: session.pageUrl,
            clientSecret: session.clientSecret,
            publishableKey: session.publishableKey,
            dark: dark,
            accent: AppColors.accentOn(context),
            onEvent: _onEvent,
          );
        },
      ),
    );
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
                  style: TextStyle(color: Colors.grey.shade600)),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => setState(
                    () => _session = PaymentService.instance.connectSession()),
                child: const Text('Try again'),
              ),
            ],
          ),
        ),
      );
}
