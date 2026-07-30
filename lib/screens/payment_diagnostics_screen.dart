import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../payments/payment_diagnostics.dart';

/// "Check payments setup": runs the payments chain and says which link is
/// broken.
///
/// Payments failing produced one sentence from Stripe — "an error occurred
/// while authenticating your account" — which names neither of the two things
/// that cause it. Working that out meant several rounds of asking somebody to
/// go and read a dashboard. This asks instead, and prints an answer that can be
/// copied into a message.
class PaymentDiagnosticsScreen extends StatefulWidget {
  const PaymentDiagnosticsScreen({super.key});

  @override
  State<PaymentDiagnosticsScreen> createState() =>
      _PaymentDiagnosticsScreenState();
}

class _PaymentDiagnosticsScreenState extends State<PaymentDiagnosticsScreen> {
  PaymentDiagnostics? _result;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    setState(() => _running = true);
    final result = await PaymentsSelfTest.run();
    if (!mounted) return;
    setState(() {
      _result = result;
      _running = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Check payments setup'),
        actions: [
          if (result != null)
            IconButton(
              icon: const Icon(Icons.copy_all_outlined),
              tooltip: 'Copy report',
              onPressed: () {
                Clipboard.setData(ClipboardData(text: result.report));
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Report copied.')));
              },
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Run again',
            onPressed: _running ? null : _run,
          ),
        ],
      ),
      body: result == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                for (final step in result.steps)
                  ListTile(
                    leading: Icon(
                      switch (step.state) {
                        CheckState.pass => Icons.check_circle,
                        CheckState.fail => Icons.error,
                        CheckState.unknown => Icons.help_outline,
                      },
                      color: switch (step.state) {
                        CheckState.pass => Colors.green,
                        CheckState.fail => Colors.red,
                        CheckState.unknown => Colors.orange,
                      },
                    ),
                    title: Text(step.title,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(step.detail),
                  ),
                const Divider(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(result.faulty ? 'What to change' : 'Result',
                          style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.6)),
                      const SizedBox(height: 8),
                      Text(result.verdict,
                          style: const TextStyle(fontSize: 15, height: 1.35)),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}
