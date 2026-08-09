import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../payments/lightning.dart';
import '../theme/app_theme.dart';

/// Send a creator a Lightning spark — bitcoin, straight from the sender's own
/// wallet to the creator's, the way a Nostr zap works.
///
/// Three steps and the app only does the middle one: resolve the creator's
/// Lightning Address, ask their server for an invoice, hand that invoice to
/// the sender's wallet app. No balance is held here and no cut is taken; see
/// `lightning.dart` for why that shape is also the one Apple permits.
Future<void> showLightningSparkSheet(
  BuildContext context, {
  required String address,
  required String name,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _SparkSheet(address: address, name: name),
  );
}

class _SparkSheet extends StatefulWidget {
  final String address;
  final String name;
  const _SparkSheet({required this.address, required this.name});

  @override
  State<_SparkSheet> createState() => _SparkSheetState();
}

class _SparkSheetState extends State<_SparkSheet> {
  LnurlPayParams? _params;
  bool _loading = true;

  /// Names what went wrong rather than a shrug: the three failures here
  /// (unreadable address, unreachable server, refused amount) need different
  /// things from the person reading.
  String _error = '';
  int _sats = 100;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  Future<void> _resolve() async {
    final parsed = LightningAddress.parse(widget.address);
    if (parsed == null) {
      setState(() {
        _loading = false;
        _error = 'That is not a usable Lightning address.';
      });
      return;
    }
    final params = await Lightning.resolve(parsed);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _params = params;
      _error = params == null
          ? 'Could not reach ${parsed.domain}. Their wallet server may be '
              'down, or the address may be wrong.'
          : '';
      if (params != null) {
        // Start on a preset their server will actually accept, so the first
        // tap is never refused.
        _sats = _sats.clamp(params.minSats, params.maxSats);
      }
    });
  }

  Future<void> _send() async {
    final params = _params;
    if (params == null || _sending) return;
    setState(() {
      _sending = true;
      _error = '';
    });
    final invoice = await Lightning.invoice(params, _sats);
    if (!mounted) return;
    if (invoice == null) {
      setState(() {
        _sending = false;
        _error = 'Their server would not issue an invoice for that amount.';
      });
      return;
    }
    final uri = Lightning.walletUri(invoice);
    var opened = false;
    try {
      // Plain launchUrl, no explicit mode: 'lightning:' is not http, so the
      // system routes it to whichever wallet registered the scheme. Asking
      // for a browser mode would be both wrong and against the app's rule
      // that it never sends anybody to a browser.
      opened = await launchUrl(uri);
    } catch (_) {
      opened = false;
    }
    if (!mounted) return;
    if (!opened) {
      setState(() {
        _sending = false;
        _error = 'No Lightning wallet is installed to open this with.';
      });
      return;
    }
    // The wallet has it; this is the end of what the app can observe, so the
    // sheet closes rather than claiming the spark was paid.
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final subtle = AppColors.subtle(context);
    final params = _params;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Spark ${widget.name}',
                textAlign: TextAlign.center,
                style:
                    const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(widget.address,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, color: subtle)),
            const SizedBox(height: 16),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 30),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (params == null) ...[
              Text(_error,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13.5, color: subtle)),
              const SizedBox(height: 14),
              OutlinedButton(
                onPressed: () {
                  setState(() => _loading = true);
                  _resolve();
                },
                child: const Text('Try again'),
              ),
            ] else ...[
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final s in Lightning.presetSats)
                    if (params.allows(s))
                      ChoiceChip(
                        label: Text('$s sats'),
                        selected: s == _sats,
                        showCheckmark: false,
                        onSelected: (_) => setState(() => _sats = s),
                      ),
                ],
              ),
              const SizedBox(height: 8),
              Text('${params.minSats}–${params.maxSats} sats accepted',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: subtle)),
              if (_error.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(_error,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 12.5, color: Colors.redAccent)),
              ],
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _sending ? null : _send,
                icon: const Icon(Icons.bolt, size: 18),
                label: Text(_sending ? 'Opening wallet…' : 'Send $_sats sats'),
              ),
              const SizedBox(height: 10),
              Text(
                'This opens your Lightning wallet to pay. The bitcoin goes '
                'straight to them — Okay never holds it and takes no cut, '
                'which also means it cannot confirm the payment. Your wallet '
                'is what tells you it went through.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11.5, height: 1.35, color: subtle),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
