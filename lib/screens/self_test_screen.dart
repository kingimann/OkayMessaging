import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/self_test.dart';

/// Runs a self-test and prints what it found, with a copy button.
///
/// The copy button is the reason this is a screen rather than a dialog: the
/// answers these tests produce are the ones somebody needs to paste into a
/// message to get help, and re-typing a verdict loses exactly the detail that
/// made it worth having.
class SelfTestScreen extends StatefulWidget {
  const SelfTestScreen({super.key, required this.title, required this.run});

  final String title;

  /// The test itself. Called on open and on every "Run again".
  final Future<SelfTestReport> Function() run;

  @override
  State<SelfTestScreen> createState() => _SelfTestScreenState();
}

class _SelfTestScreenState extends State<SelfTestScreen> {
  SelfTestReport? _result;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    setState(() => _running = true);
    final result = await widget.run();
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
        title: Text(widget.title),
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
