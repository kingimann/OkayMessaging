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

/// One line of plain English about where a payment's money is — the thing a
/// tapped "Failed" row most wants to explain. Pure, so a test can pin each
/// state's wording without pumping the screen.
String paymentExplanation(PaymentRecord t) {
  if (t.isBlocked) return t.blockedReason;
  if (t.status == 'canceled') {
    return 'This payment was canceled — no money moved.';
  }
  if (t.isCanceled || (!t.isComplete && !t.isPending)) {
    return 'This payment didn\'t go through — nothing was charged. If it was '
        'a top-up, the card may have been declined or your payout account '
        'isn\'t ready to receive yet.';
  }
  if (t.isPending) {
    return t.status == 'in_transit'
        ? 'On its way to the destination.'
        : 'Waiting to settle — this can take a moment.';
  }
  if (t.isPayout) return 'Paid out to your bank or card.';
  return t.sent ? 'Sent successfully.' : 'Received.';
}

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

  /// Colour, icon and short label for a record's state — shared by the row and
  /// the detail sheet so they never drift.
  ({Color colour, IconData icon, String label}) _statusMeta(PaymentRecord t) {
    final sent = t.sent;
    if (t.isBlocked) {
      return (colour: Colors.orange.shade700, icon: Icons.block, label: t.blockedReason);
    } else if (t.isCanceled) {
      return (
        colour: Colors.red.shade400,
        icon: Icons.close,
        label: t.status == 'canceled' ? 'Canceled' : 'Failed'
      );
    } else if (t.isPending) {
      return (
        colour: Colors.grey,
        icon: Icons.schedule,
        label: t.status == 'in_transit' ? 'On its way' : 'Pending'
      );
    } else if (!t.isComplete) {
      return (colour: Colors.red.shade400, icon: Icons.close, label: 'Failed');
    } else if (t.isPayout) {
      return (colour: const Color(0xFF2E90FA), icon: Icons.account_balance, label: 'Paid out');
    } else if (t.isSpark) {
      return (
        colour: const Color(0xFFF7931A),
        icon: Icons.bolt,
        label: sent ? 'Sparked' : 'Spark received'
      );
    }
    return (
      colour: sent ? Colors.red.shade400 : const Color(0xFF12B76A),
      icon: sent ? Icons.arrow_upward : Icons.arrow_downward,
      label: sent ? 'Sent' : 'Received'
    );
  }

  String _title(PaymentRecord t) => t.isPayout
      ? 'Cash out (${t.method == 'instant' ? 'instant' : 'standard'})'
      : formatPhoneForDisplay(t.otherPhone);

  Widget _row(BuildContext context, PaymentRecord t) {
    final sent = t.sent;
    final amount = '\$${(t.amountCents / 100).toStringAsFixed(2)}';
    final meta = _statusMeta(t);
    final note = t.isSpark || t.isPayout ? '' : t.note.trim();
    return ListTile(
      onTap: () => _showDetail(context, t),
      leading: CircleAvatar(
        backgroundColor: meta.colour.withValues(alpha: 0.15),
        child: Icon(meta.icon, color: meta.colour, size: 20),
      ),
      title: Text(_title(t)),
      subtitle: Text(
        [
          if (note.isNotEmpty) note,
          t.at == null ? meta.label : '${meta.label} · ${_when(t.at!)}',
        ].join('\n'),
        style: TextStyle(fontSize: 12.5, color: AppColors.subtle(context)),
      ),
      isThreeLine: note.isNotEmpty,
      trailing: Text(
        // Only money that actually left the account carries a minus sign.
        '${t.isComplete && sent ? '−' : ''}$amount',
        style: TextStyle(
          fontWeight: FontWeight.w700,
          color: t.isComplete ? meta.colour : Colors.grey,
        ),
      ),
    );
  }

  void _showDetail(BuildContext context, PaymentRecord t) {
    final meta = _statusMeta(t);
    final amount = '\$${(t.amountCents / 100).toStringAsFixed(2)}';
    final kind = t.isPayout
        ? 'Cash out'
        : t.isSpark
            ? 'Spark'
            : 'Transfer';
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    backgroundColor: meta.colour.withValues(alpha: 0.15),
                    child: Icon(meta.icon, color: meta.colour),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${t.isComplete && t.sent ? '−' : ''}$amount',
                          style: const TextStyle(
                              fontSize: 24, fontWeight: FontWeight.w800),
                        ),
                        Text(meta.label,
                            style: TextStyle(
                                color: meta.colour,
                                fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(paymentExplanation(t),
                  style: TextStyle(
                      color: AppColors.subtle(context), height: 1.4)),
              const SizedBox(height: 16),
              const Divider(height: 1),
              _detailRow(context, t.isPayout ? 'Destination' : 'With',
                  _title(t)),
              _detailRow(context, 'Type', kind),
              if (t.isPayout && t.method.isNotEmpty)
                _detailRow(context, 'Method',
                    t.method == 'instant' ? 'Instant' : 'Standard'),
              _detailRow(context, 'Direction', t.sent ? 'Outgoing' : 'Incoming'),
              if (t.feeCents > 0)
                _detailRow(context, 'Fee',
                    '\$${(t.feeCents / 100).toStringAsFixed(2)}'),
              if (t.at != null)
                _detailRow(context, 'When', _fullWhen(t.at!)),
              if (t.note.trim().isNotEmpty && !t.isSpark)
                _detailRow(context, 'Note', t.note.trim()),
              _detailRow(context, 'Reference', t.id),
            ],
          ),
        ),
      ),
    );
  }

  Widget _detailRow(BuildContext context, String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 96,
              child: Text(label,
                  style: TextStyle(color: AppColors.subtle(context))),
            ),
            Expanded(
              child: Text(value,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      );

  String _fullWhen(DateTime at) {
    final l = at.toLocal();
    final h = l.hour % 12 == 0 ? 12 : l.hour % 12;
    final ampm = l.hour < 12 ? 'AM' : 'PM';
    return '${l.year}-${l.month.toString().padLeft(2, '0')}-'
        '${l.day.toString().padLeft(2, '0')} '
        '$h:${l.minute.toString().padLeft(2, '0')} $ampm';
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
