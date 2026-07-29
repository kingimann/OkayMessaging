import 'package:flutter/material.dart';

import '../payments/payment_service.dart';
import '../util/phone_format.dart';

/// Who may pay you, and how much you can send in a day.
///
/// Both are stored and enforced on the server. A limit the app applies is a
/// limit a modified app ignores, and the point of a limit is that it holds
/// when something has gone wrong.
class PaymentControlsScreen extends StatefulWidget {
  const PaymentControlsScreen({super.key});

  @override
  State<PaymentControlsScreen> createState() => _PaymentControlsScreenState();
}

class _PaymentControlsScreenState extends State<PaymentControlsScreen> {
  late Future<PaymentControls> _future = PaymentService.instance.controls();
  bool _busy = false;

  Future<void> _update({
    String? acceptsFrom,
    int? dailySendLimitCents,
    String? unblock,
  }) async {
    setState(() => _busy = true);
    try {
      final next = await PaymentService.instance.controls(
        acceptsFrom: acceptsFrom,
        dailySendLimitCents: dailySendLimitCents,
        unblock: unblock,
      );
      if (mounted) setState(() => _future = Future.value(next));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not save that. Try again.')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Payment controls')),
      body: FutureBuilder<PaymentControls>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final c = snap.data ?? const PaymentControls();
          return ListView(
            children: [
              _header('Receiving'),
              SwitchListTile(
                value: c.acceptsAnyone,
                onChanged: _busy
                    ? null
                    : (v) =>
                        _update(acceptsFrom: v ? 'anyone' : 'nobody'),
                title: const Text('Let people send me money'),
                subtitle: Text(c.acceptsAnyone
                    ? 'Anyone who knows your number can pay you'
                    : 'Nobody can send you money right now'),
              ),
              if (c.blocked.isNotEmpty) ...[
                _header('Blocked from paying you'),
                for (final phone in c.blocked)
                  ListTile(
                    leading: const Icon(Icons.block, size: 20),
                    title: Text(formatPhoneForDisplay(phone)),
                    trailing: TextButton(
                      onPressed:
                          _busy ? null : () => _update(unblock: phone),
                      child: const Text('Unblock'),
                    ),
                  ),
              ],
              _header('Sending'),
              ListTile(
                title: const Text('Daily limit'),
                subtitle: Text(
                  'At most \$${(c.dailySendLimitCents / 100).toStringAsFixed(0)} '
                  'can leave this account in 24 hours.',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: _busy ? null : () => _pickLimit(c),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                child: Text(
                  'A daily limit bounds what a phone in someone else\'s hands '
                  'can move, and what one bad afternoon can cost. It is '
                  'checked on the server, so it holds even if the app is '
                  'not the one asking.',
                  style:
                      TextStyle(fontSize: 12.5, color: Colors.grey.shade600),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _header(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
        child: Text(text.toUpperCase(),
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: Colors.grey.shade600)),
      );

  Future<void> _pickLimit(PaymentControls current) async {
    const options = [5000, 10000, 25000, 50000, 100000, 200000];
    final picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Text('Daily send limit',
                  style:
                      TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            ),
            for (final cents in options)
              ListTile(
                title: Text('\$${(cents / 100).toStringAsFixed(0)}'),
                trailing: cents == current.dailySendLimitCents
                    ? const Icon(Icons.check, color: Color(0xFF12B76A))
                    : null,
                onTap: () => Navigator.pop(sheetContext, cents),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked != null) await _update(dailySendLimitCents: picked);
  }
}
