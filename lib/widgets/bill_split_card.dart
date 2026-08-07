import 'package:flutter/material.dart';

import '../models/message.dart';
import '../theme/app_theme.dart';

/// The split-bill card shown in a conversation: the total, each person's
/// share and whether they've paid, and — for the person looking at it — a
/// "Pay my share" button when they still owe.
class BillSplitCard extends StatelessWidget {
  final Message message;
  final String myPhone;

  /// Runs the reimbursement to the bill's creator; null when this device is
  /// the creator (you don't pay yourself) or already paid.
  final VoidCallback? onPayShare;

  const BillSplitCard({
    super.key,
    required this.message,
    required this.myPhone,
    this.onPayShare,
  });

  static String _digits(String p) => p.replaceAll(RegExp(r'\D'), '');
  static String _money(int cents) => '\$${(cents / 100).toStringAsFixed(2)}';

  @override
  Widget build(BuildContext context) {
    final bill = message.billSplit!;
    final iAmOwner = _digits(myPhone) == _digits(bill.createdByPhone);
    final mine = bill.shareFor(myPhone);
    final accent = AppColors.accentOn(context);

    return Container(
      constraints: const BoxConstraints(maxWidth: 320),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? AppColors.darkAppBar
            : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.receipt_long, color: accent, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(bill.title,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 15),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
              Text(_money(bill.totalCents),
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 4),
          Text('Split ${bill.shares.length} ways',
              style: TextStyle(fontSize: 12, color: AppColors.subtle(context))),
          const Divider(height: 16),
          for (final s in bill.shares)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Icon(
                    s.paid ? Icons.check_circle : Icons.circle_outlined,
                    size: 16,
                    color: s.paid ? Colors.green : AppColors.subtle(context),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _digits(s.phone) == _digits(myPhone) ? 'You' : s.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(_money(s.cents),
                      style: TextStyle(
                        color: s.paid ? Colors.green : null,
                        fontWeight: FontWeight.w600,
                      )),
                ],
              ),
            ),
          const SizedBox(height: 10),
          _footer(context, bill, iAmOwner, mine),
        ],
      ),
    );
  }

  Widget _footer(BuildContext context, bill, bool iAmOwner, mine) {
    if (bill.settled) {
      return const Row(
        children: [
          Icon(Icons.verified, color: Colors.green, size: 18),
          SizedBox(width: 6),
          Text('Everyone\'s settled up',
              style: TextStyle(
                  color: Colors.green, fontWeight: FontWeight.w600)),
        ],
      );
    }
    if (iAmOwner) {
      return Text(
        '${_money(bill.collectedCents)} of ${_money(bill.outstandingCents + bill.collectedCents)} collected',
        style: TextStyle(color: AppColors.subtle(context), fontSize: 13),
      );
    }
    if (mine != null && !mine.paid) {
      return SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: onPayShare,
          icon: const Icon(Icons.send, size: 18),
          label: Text('Pay your share · ${_money(mine.cents)}'),
        ),
      );
    }
    // A debtor who has paid, or someone not on the bill.
    return Text(
      mine != null ? 'You\'ve paid your share' : 'You\'re not on this bill',
      style: TextStyle(color: AppColors.subtle(context), fontSize: 13),
    );
  }
}
