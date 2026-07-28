import 'package:flutter/material.dart';

import 'storage_economics.dart';
import 'package:flutter/services.dart';

/// A bottom sheet to enter an amount and optional note before sending money.
/// Returns `(cents, note, acknowledged)` on confirm, or null on cancel.
class PaymentAmountSheet extends StatefulWidget {
  final String peerName;
  const PaymentAmountSheet({super.key, required this.peerName});

  @override
  State<PaymentAmountSheet> createState() => _PaymentAmountSheetState();
}

class _PaymentAmountSheetState extends State<PaymentAmountSheet> {
  final _amount = TextEditingController();
  final _note = TextEditingController();

  int get _cents {
    final v = double.tryParse(_amount.text) ?? 0;
    return (v * 100).round();
  }

  bool get _valid => _cents >= 50; // Stripe minimum ~$0.50

  /// Whether the sender has ticked the "this is final" box. Required before
  /// sending: the paper trail is only worth having if it is always there.
  bool _acknowledged = false;

  /// The platform fee for the amount typed. Same arithmetic the Edge Function
  /// applies, so the number quoted here is the number actually charged.
  int get _feeCents =>
      _cents <= 0 ? 0 : PaymentEconomics.applicationFeeCents(_cents);

  /// Roughly what lands. Approximate on purpose: this is a direct charge, so
  /// the recipient's account also pays Stripe's processing fee, and Stripe's
  /// rate depends on where the sender's card was issued — which nobody knows
  /// until the charge goes through.
  int get _receivedCents =>
      _cents <= 0 ? 0 : PaymentEconomics.estimatedReceivedCents(_cents);

  Widget _feeRow(BuildContext context, String label, int cents,
      {bool muted = false, bool bold = false}) {
    final style = TextStyle(
      fontSize: bold ? 15 : 13.5,
      fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
      color: muted ? Colors.grey.shade600 : null,
    );
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Flexible(
            child: Text(label,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: style)),
        Text('\$${(cents / 100).toStringAsFixed(2)}', style: style),
      ],
    );
  }

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: SafeArea(
        // The sheet grew a fee breakdown and a confirmation, and with the
        // keyboard up it no longer fits a small phone. Scrolling is the only
        // honest answer — clipping would hide the very numbers this sheet
        // exists to show.
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 18),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade400,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Text('Send money to ${widget.peerName}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w600)),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text('\$',
                          style: TextStyle(
                              fontSize: 30, fontWeight: FontWeight.w600)),
                    ),
                    const SizedBox(width: 4),
                    IntrinsicWidth(
                      child: TextField(
                        controller: _amount,
                        autofocus: true,
                        textAlign: TextAlign.center,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(
                              RegExp(r'^\d*\.?\d{0,2}')),
                        ],
                        style: const TextStyle(
                            fontSize: 46, fontWeight: FontWeight.w700),
                        decoration: const InputDecoration(
                          hintText: '0',
                          border: InputBorder.none,
                          isDense: true,
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text('CAD',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey, fontSize: 13)),
                const SizedBox(height: 20),
                TextField(
                  controller: _note,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    hintText: 'Add a note (optional)',
                    filled: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 14),
                  ),
                ),
                // What the fee actually is, before anyone commits to paying it.
                // The fee comes out of the transfer, so the amount typed and the
                // amount that lands are different numbers — saying so plainly is
                // the only honest way to show this.
                if (_valid) ...[
                  const SizedBox(height: 18),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest
                          .withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Column(
                      children: [
                        _feeRow(context, 'You pay', _cents),
                        const SizedBox(height: 6),
                        _feeRow(context, 'Our fee', _feeCents, muted: true),
                        const SizedBox(height: 6),
                        _feeRow(context, 'Card processing',
                            PaymentEconomics.stripeCostCents(_cents),
                            muted: true),
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: Divider(height: 1),
                        ),
                        _feeRow(context, '${widget.peerName} gets about',
                            _receivedCents,
                            bold: true),
                        const SizedBox(height: 6),
                        Text(
                          'Money goes straight to ${widget.peerName} — we never '
                          'hold it. Card processing is charged to them and can '
                          'be a little higher on a foreign card.',
                          style: TextStyle(
                              fontSize: 11.5, color: Colors.grey.shade600),
                        ),
                      ],
                    ),
                  ),
                ],
                // A tick that says, in the sender's own action, that they know
                // this is final. It exists to stop the dispute rather than win
                // it: most chargebacks on transfers like this are people who
                // changed their mind, not fraud.
                if (_valid) ...[
                  const SizedBox(height: 12),
                  InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => setState(() => _acknowledged = !_acknowledged),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Checkbox(
                            value: _acknowledged,
                            visualDensity: VisualDensity.compact,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                            onChanged: (v) =>
                                setState(() => _acknowledged = v ?? false),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              'I understand this goes straight to '
                              '${widget.peerName} and cannot be reversed. '
                              'Reversing it through my bank will block me from '
                              'sending money here.',
                              style: TextStyle(
                                  fontSize: 12, color: Colors.grey.shade700),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF12B76A),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                  onPressed: _valid && _acknowledged
                      ? () => Navigator.of(context).pop((
                            cents: _cents,
                            note: _note.text.trim(),
                            acknowledged: _acknowledged,
                          ))
                      : null,
                  child: Text(
                    !_valid
                        ? 'Enter an amount'
                        : (_acknowledged
                            ? 'Send \$${(_cents / 100).toStringAsFixed(2)}'
                            : 'Confirm to continue'),
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.lock, size: 13, color: Colors.grey.shade500),
                    const SizedBox(width: 5),
                    Text('Secured by Stripe',
                        style: TextStyle(
                            color: Colors.grey.shade500, fontSize: 12)),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The in-bubble payment receipt shown for an [isPayment] message.
class PaymentBubble extends StatelessWidget {
  final int amountCents;
  final String note;
  final bool isMe;

  /// 'pending', 'paid', 'failed', or '' (treated as settled for older
  /// receipts that predate status tracking).
  final String status;

  const PaymentBubble({
    super.key,
    required this.amountCents,
    required this.note,
    required this.isMe,
    this.status = '',
  });

  bool get _pending => status == 'pending';
  bool get _failed => status == 'failed';

  @override
  Widget build(BuildContext context) {
    final amount = '\$${(amountCents / 100).toStringAsFixed(2)}';
    final colors = _failed
        ? const [Color(0xFF9AA4AE), Color(0xFF7E8892)]
        : _pending
            ? const [Color(0xFF3F8F6B), Color(0xFF2E7D5B)]
            : const [Color(0xFF12B76A), Color(0xFF0E9F63)];
    final title = _failed
        ? 'Payment failed'
        : isMe
            ? 'Payment sent'
            : 'Payment received';
    return Container(
      width: 210,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(_failed ? Icons.error_outline : Icons.payments_rounded,
                  color: Colors.white, size: 20),
              const SizedBox(width: 8),
              Text(title,
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 13)),
            ],
          ),
          const SizedBox(height: 10),
          Text(amount,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 30,
                  fontWeight: FontWeight.w800)),
          if (note.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(note,
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.9), fontSize: 13)),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              _StatusPill(status: status),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text('Stripe',
                    style: TextStyle(color: Colors.white, fontSize: 10.5)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A small status chip inside the payment bubble.
class _StatusPill extends StatelessWidget {
  final String status;
  const _StatusPill({required this.status});

  @override
  Widget build(BuildContext context) {
    final (icon, label) = switch (status) {
      'pending' => (Icons.schedule, 'Pending'),
      'failed' => (Icons.close, 'Failed'),
      _ => (Icons.check_circle, 'Completed'),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 12),
          const SizedBox(width: 3),
          Text(label,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
