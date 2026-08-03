import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

import '../payments/payment_service.dart';
import '../util/phone_format.dart';

/// The lenses the history can be read through. 'all' is the timeline;
/// the rest each answer one question — what did I spark, what is still in
/// flight, what left for my bank, what never moved.
const List<(String, String)> paymentHistoryFilters = [
  ('all', 'All'),
  ('sparks', 'Sparks'),
  ('pending', 'Pending'),
  ('payouts', 'Cash outs'),
  ('canceled', 'Canceled'),
];

/// Applies one filter key to the records. Pure, so a test can hold each
/// lens to a known list without pumping the screen.
List<PaymentRecord> filterPaymentRecords(
    List<PaymentRecord> records, String filter) {
  return switch (filter) {
    'sparks' => [for (final r in records) if (r.isSpark) r],
    'pending' => [for (final r in records) if (r.isPending) r],
    'payouts' => [for (final r in records) if (r.isPayout) r],
    'canceled' => [for (final r in records) if (r.isCanceled) r],
    _ => records,
  };
}

/// Every movement of money this account has been part of: transfers sent and
/// received, sparks, and the cash-outs that took the balance to a bank or
/// card.
///
/// Read from the server rather than the device: a transfer has two sides and
/// only one of them is this phone, so the chat alone can never show the whole
/// picture — and money you received while the app was closed has to appear
/// somewhere.
class PaymentHistoryScreen extends StatefulWidget {
  const PaymentHistoryScreen({super.key});

  @override
  State<PaymentHistoryScreen> createState() => _PaymentHistoryScreenState();
}

class _PaymentHistoryScreenState extends State<PaymentHistoryScreen> {
  late Future<List<PaymentRecord>> _future = PaymentService.instance.history();
  String _filter = 'all';

  Future<void> _refresh() async {
    setState(() => _future = PaymentService.instance.history());
    await _future;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Transactions')),
      body: Column(
        children: [
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              children: [
                for (final (key, label) in paymentHistoryFilters)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(label),
                      selected: _filter == key,
                      onSelected: (_) => setState(() => _filter = key),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: FutureBuilder<List<PaymentRecord>>(
                future: _future,
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snap.hasError) {
                    return _empty('Could not load transactions.');
                  }
                  final items = filterPaymentRecords(
                      snap.data ?? const <PaymentRecord>[], _filter);
                  if (items.isEmpty) {
                    return _empty(switch (_filter) {
                      'sparks' => 'No sparks yet.',
                      'pending' => 'Nothing pending.',
                      'payouts' => 'No cash outs yet.',
                      'canceled' => 'Nothing canceled.',
                      _ => 'No transfers yet.',
                    });
                  }
                  return ListView.separated(
                    itemCount: items.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) => _row(context, items[i]),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Always scrollable, so pull-to-refresh still works with nothing in it.
  Widget _empty(String message) => ListView(
        children: [
          const SizedBox(height: 120),
          Icon(Icons.receipt_long_outlined,
              size: 48, color: Colors.grey.shade400),
          const SizedBox(height: 12),
          Center(
            child: Text(message,
                style: TextStyle(color: AppColors.subtle(context))),
          ),
        ],
      );

  Widget _row(BuildContext context, PaymentRecord t) {
    final sent = t.sent;
    final amount = '\$${(t.amountCents / 100).toStringAsFixed(2)}';
    final Color colour;
    final IconData icon;
    final String label;
    if (t.isBlocked) {
      colour = Colors.orange.shade700;
      icon = Icons.block;
      label = t.blockedReason;
    } else if (t.isCanceled) {
      colour = Colors.red.shade400;
      icon = Icons.close;
      label = t.status == 'canceled' ? 'Canceled' : 'Failed';
    } else if (t.isPending) {
      colour = Colors.grey;
      icon = Icons.schedule;
      label = t.status == 'in_transit' ? 'On its way' : 'Pending';
    } else if (!t.isComplete) {
      colour = Colors.red.shade400;
      icon = Icons.close;
      label = 'Failed';
    } else if (t.isPayout) {
      colour = const Color(0xFF2E90FA);
      icon = Icons.account_balance;
      label = 'Paid out';
    } else if (t.isSpark) {
      colour = const Color(0xFFF7931A);
      icon = Icons.bolt;
      label = sent ? 'Sparked' : 'Spark received';
    } else {
      colour = sent ? Colors.red.shade400 : const Color(0xFF12B76A);
      icon = sent ? Icons.arrow_upward : Icons.arrow_downward;
      label = sent ? 'Sent' : 'Received';
    }
    // A payout's counterparty is this account's own bank or card — there is
    // no other phone to name.
    final title = t.isPayout
        ? 'Cash out (${t.method == 'instant' ? 'instant' : 'standard'})'
        : formatPhoneForDisplay(t.otherPhone);
    final note = t.isSpark || t.isPayout ? '' : t.note.trim();
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: colour.withValues(alpha: 0.15),
        child: Icon(icon, color: colour, size: 20),
      ),
      title: Text(title),
      subtitle: Text(
        [
          if (note.isNotEmpty) note,
          t.at == null ? label : '$label · ${_when(t.at!)}',
        ].join('\n'),
        style: TextStyle(fontSize: 12.5, color: AppColors.subtle(context)),
      ),
      isThreeLine: note.isNotEmpty,
      trailing: Text(
        // Only money that actually left the account carries a minus sign.
        '${t.isComplete && sent ? '−' : ''}$amount',
        style: TextStyle(
          fontWeight: FontWeight.w700,
          color: t.isComplete ? colour : Colors.grey,
        ),
      ),
    );
  }

  String _when(DateTime at) {
    final d = DateTime.now().difference(at);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes}m ago';
    if (d.inDays < 1) return '${d.inHours}h ago';
    if (d.inDays < 7) return '${d.inDays}d ago';
    return '${at.year}-${at.month.toString().padLeft(2, '0')}-'
        '${at.day.toString().padLeft(2, '0')}';
  }
}
