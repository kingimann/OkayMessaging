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
class IdentityCheckScreen extends StatefulWidget {
  final IdentitySession session;
  const IdentityCheckScreen({super.key, required this.session});

  @override
  State<IdentityCheckScreen> createState() => _IdentityCheckScreenState();
}

class _IdentityCheckScreenState extends State<IdentityCheckScreen> {
  void _onEvent(String event) {
    if (!mounted) return;
    // 'submitted' means Stripe has the documents; the verdict arrives later by
    // webhook, so the caller re-reads it rather than trusting this screen.
    if (event == 'submitted' || event == 'exit') {
      Navigator.of(context).pop(event == 'submitted');
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final key = widget.session.publishableKey.isNotEmpty
        ? widget.session.publishableKey
        : PaymentService.publishableKey;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Verify your identity'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Cancel',
          onPressed: () => Navigator.of(context).pop(false),
        ),
      ),
      body: !ConnectWebView.isSupported || key.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  'Verifying your identity needs the mobile app.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey.shade600),
                ),
              ),
            )
          : ConnectWebView.build(
              url: IdentityVerification.pageUrl,
              clientSecret: widget.session.clientSecret,
              publishableKey: key,
              dark: dark,
              accent: AppColors.accentOn(context),
              onEvent: _onEvent,
              // Document capture and the selfie need the camera.
              needsCamera: true,
            ),
    );
  }
}
