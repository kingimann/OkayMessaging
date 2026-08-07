import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/bill_split.dart';
import '../theme/app_theme.dart';

/// One person the bill can be split across.
class BillParticipant {
  final String name;
  final String phone;

  /// The creator — shown as "You", pre-marked paid (they fronted the bill).
  final bool isMe;
  const BillParticipant(
      {required this.name, required this.phone, this.isMe = false});
}

/// Composes a split bill: a title, a total, and each person's share — equal by
/// default, editable per person. Returns the [BillSplit] on send, or null on
/// cancel. The creator (`isMe`) is a share too but starts paid.
Future<BillSplit?> showBillSplitSheet(
  BuildContext context, {
  required List<BillParticipant> participants,
  required String myPhone,
  String currency = 'cad',
}) {
  return showModalBottomSheet<BillSplit>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => Padding(
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom),
      child: _BillSplitSheet(
        participants: participants,
        myPhone: myPhone,
        currency: currency,
      ),
    ),
  );
}

class _BillSplitSheet extends StatefulWidget {
  final List<BillParticipant> participants;
  final String myPhone;
  final String currency;
  const _BillSplitSheet({
    required this.participants,
    required this.myPhone,
    required this.currency,
  });

  @override
  State<_BillSplitSheet> createState() => _BillSplitSheetState();
}

class _BillSplitSheetState extends State<_BillSplitSheet> {
  final _title = TextEditingController();
  final _total = TextEditingController();
  late final List<TextEditingController> _shares;
  bool _custom = false;

  @override
  void initState() {
    super.initState();
    _shares = [for (final _ in widget.participants) TextEditingController()];
    _total.addListener(_redistribute);
  }

  @override
  void dispose() {
    _title.dispose();
    _total.dispose();
    for (final c in _shares) {
      c.dispose();
    }
    super.dispose();
  }

  int get _totalCents => _dollarsToCents(_total.text);

  static int _dollarsToCents(String raw) {
    final v = double.tryParse(raw.trim().replaceAll(',', ''));
    if (v == null || v < 0) return 0;
    return (v * 100).round();
  }

  static String _cents(int c) => (c / 100).toStringAsFixed(2);

  /// Splits the total equally into the share fields — the default, and what
  /// "Split equally" resets to.
  void _redistribute() {
    if (_custom) return;
    final parts = BillSplit.equalCents(_totalCents, widget.participants.length);
    for (var i = 0; i < _shares.length; i++) {
      _shares[i].text = parts[i] == 0 ? '' : _cents(parts[i]);
    }
    setState(() {});
  }

  int get _sumCents =>
      _shares.fold(0, (n, c) => n + _dollarsToCents(c.text));

  void _submit() {
    final total = _totalCents;
    if (total <= 0) {
      _err('Enter the bill total.');
      return;
    }
    final sum = _sumCents;
    // Allow a cent of rounding slack, but not a real mismatch.
    if ((sum - total).abs() > widget.participants.length) {
      _err('The shares add up to \$${_cents(sum)}, not \$${_cents(total)}.');
      return;
    }
    final owner = widget.myPhone.replaceAll(RegExp(r'\D'), '');
    final shares = <BillShare>[
      for (var i = 0; i < widget.participants.length; i++)
        BillShare(
          name: widget.participants[i].isMe ? 'You' : widget.participants[i].name,
          phone: widget.participants[i].phone,
          cents: _dollarsToCents(_shares[i].text),
          // The creator already covered the whole bill; everyone else owes.
          paid: widget.participants[i].phone.replaceAll(RegExp(r'\D'), '') ==
              owner,
        ),
    ];
    Navigator.of(context).pop(BillSplit(
      title: _title.text.trim().isEmpty ? 'Bill' : _title.text.trim(),
      totalCents: total,
      currency: widget.currency,
      createdByPhone: widget.myPhone,
      shares: shares,
    ));
  }

  void _err(String m) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
    final remaining = _totalCents - _sumCents;
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Split a bill',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 14),
            TextField(
              controller: _title,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'What for',
                hintText: 'Dinner, groceries…',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _total,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))
              ],
              decoration: const InputDecoration(
                labelText: 'Total',
                prefixText: '\$ ',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text('${widget.participants.length} people',
                    style: TextStyle(color: AppColors.subtle(context))),
                const Spacer(),
                TextButton.icon(
                  onPressed: () {
                    setState(() => _custom = false);
                    _redistribute();
                  },
                  icon: const Icon(Icons.balance, size: 18),
                  label: const Text('Split equally'),
                ),
              ],
            ),
            for (var i = 0; i < widget.participants.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.participants[i].isMe
                            ? 'You'
                            : widget.participants[i].name,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    SizedBox(
                      width: 110,
                      child: TextField(
                        controller: _shares[i],
                        onTap: () => setState(() => _custom = true),
                        onChanged: (_) => setState(() {}),
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))
                        ],
                        textAlign: TextAlign.right,
                        decoration: const InputDecoration(
                          prefixText: '\$ ',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (_totalCents > 0 && remaining != 0)
              Padding(
                padding: const EdgeInsets.only(top: 2, bottom: 6),
                child: Text(
                  remaining > 0
                      ? '\$${_cents(remaining)} left to assign'
                      : '\$${_cents(-remaining)} over the total',
                  style: const TextStyle(color: Colors.orange, fontSize: 13),
                ),
              ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _submit,
              icon: const Icon(Icons.receipt_long),
              label: const Text('Send bill'),
            ),
          ],
        ),
      ),
    );
  }
}
