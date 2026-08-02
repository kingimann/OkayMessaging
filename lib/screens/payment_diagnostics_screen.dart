import 'package:flutter/material.dart';

import '../payments/payment_diagnostics.dart';
import 'self_test_screen.dart';

/// "Check payments setup": runs the payments chain and says which link is
/// broken.
///
/// Payments failing produced one sentence from Stripe — "an error occurred
/// while authenticating your account" — which names neither of the two things
/// that cause it. Working that out meant several rounds of asking somebody to
/// go and read a dashboard. This asks instead, and prints an answer that can be
/// copied into a message.
class PaymentDiagnosticsScreen extends StatelessWidget {
  const PaymentDiagnosticsScreen({super.key});

  @override
  Widget build(BuildContext context) => const SelfTestScreen(
        title: 'Check payments setup',
        run: PaymentsSelfTest.run,
      );
}
