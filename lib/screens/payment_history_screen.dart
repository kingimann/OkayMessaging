import 'package:flutter/material.dart';

import '../payments/payment_service.dart';
import '../util/phone_format.dart';
import '../widgets/app_shell.dart';

/// Every transfer this account has been part of, sent and received.
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

  Future<void> _refresh() async {
    setState(() => _future = PaymentService.instance.history());
    await _future;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          automaticallyImplyLeading: false,
          leading: const SidebarButton(),
          title: const Text('Transactions')),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: FutureBuilder<List<PaymentRecord>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final items = snap.data ?? const <PaymentRecord>[];
            if (snap.hasError) return _empty('Could not load transactions.');
            if (items.isEmpty) return _empty('No transfers yet.');
            return ListView.separated(
              itemCount: items.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) => _row(context, items[i]),
            );
          },
        ),
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
            child: Text(message, style: TextStyle(color: Colors.grey.shade600)),
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
    } else if (t.isPending) {
      colour = Colors.grey;
      icon = Icons.schedule;
      label = 'Pending';
    } else if (!t.isComplete) {
      colour = Colors.red.shade400;
      icon = Icons.close;
      label = 'Failed';
    } else {
      colour = sent ? Colors.red.shade400 : const Color(0xFF12B76A);
      icon = sent ? Icons.arrow_upward : Icons.arrow_downward;
      label = sent ? 'Sent' : 'Received';
    }
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: colour.withValues(alpha: 0.15),
        child: Icon(icon, color: colour, size: 20),
      ),
      title: Text(formatPhoneForDisplay(t.otherPhone)),
      subtitle: Text(
        t.at == null ? label : '$label · ${_when(t.at!)}',
        style: TextStyle(fontSize: 12.5, color: Colors.grey.shade600),
      ),
      trailing: Text(
        // Only a completed send actually left the account, so only that
        // carries a minus sign.
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
