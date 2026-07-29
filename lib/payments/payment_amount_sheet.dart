import 'package:flutter/material.dart';

import '../util/phone_format.dart';
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
  /// The recipient as a person, not a digit string.
  ///
  /// A chat started from a number has the number as its name, and
  /// "14386386261" reads like an account reference rather than someone you
  /// are about to hand money to.
  String get _peer {
    final raw = widget.peerName.trim();
    if (raw.isEmpty) return 'them';
    final digits = raw.replaceAll(RegExp(r'[^0-9+]'), '');
    final looksLikeNumber =
        digits.length >= 10 && digits.length >= raw.length - 3;
    return looksLikeNumber ? formatPhoneForDisplay(raw) : raw;
  }

  final _amount = TextEditingController();
  final _note = TextEditingController();
  final _amountFocus = FocusNode();

  /// Whether the amount field has had its one automatic focus.
  ///
  /// `autofocus: true` re-requests focus whenever the field is rebuilt, and
  /// this sheet rebuilds on every keystroke — so dismissing the number pad
  /// instantly brought it back, which is why it felt impossible to close.
  /// The field autofocuses once and then stays where the user puts it.
  bool _autofocused = false;

  @override
  void initState() {
    super.initState();
    // Show/hide "Done" as the pad opens and closes.
    _amountFocus.addListener(() {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _autofocused = true);
    });
  }

  int get _cents {
    final v = double.tryParse(_amount.text) ?? 0;
    return (v * 100).round();
  }

  // Stripe's own floor is 50c, but at that size the fixed fees take 86% of
  // it. See PaymentEconomics.minimumSendCents.
  bool get _valid => PaymentEconomics.isWorthSending(_cents);

  /// Something was typed, but not enough to send.
  bool get _tooSmall => _cents > 0 && !_valid;

  /// Whether the sender has ticked the "this is final" box. Required before
  /// sending: the paper trail is only worth having if it is always there.
  bool _acknowledged = false;

  /// What the sender is charged: the amount typed plus both fees, so the
  /// recipient gets the number that was actually typed.
  int get _totalCents =>
      _cents <= 0 ? 0 : PaymentEconomics.grossUpCents(_cents);

  /// The platform's share of that total.
  int get _feeCents =>
      _cents <= 0 ? 0 : PaymentEconomics.applicationFeeCents(_totalCents);

  /// Stripe's share. Approximate: their rate depends on where the card was
  /// issued, which nobody knows until the charge goes through.
  int get _cardCents =>
      _cents <= 0 ? 0 : PaymentEconomics.stripeCostCents(_totalCents);

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
    _amountFocus.dispose();
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    final topInset = MediaQuery.of(context).padding.top;
    return Padding(
      // Only the keyboard inset here; the status bar is handled by the
      // SafeArea below. Pushed up by the keyboard the sheet grew tall enough
      // to reach the notch, and the title ended up sitting on the clock.
      padding: EdgeInsets.only(bottom: bottom),
      child: SafeArea(
        top: true,
        minimum: EdgeInsets.only(top: topInset > 0 ? 0 : 8),
        // The sheet grew a fee breakdown and a confirmation, and with the
        // keyboard up it no longer fits a small phone. Scrolling is the only
        // honest answer — clipping would hide the very numbers this sheet
        // exists to show.
        // A tap anywhere that isn't a control puts the keyboard away. The
        // amount field takes a number pad, which on iOS carries no Done or
        // Return key, so without this there is no way to get it back down.
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => FocusScope.of(context).unfocus(),
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
                      margin: const EdgeInsets.only(bottom: 10),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade400,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  // An always-visible way out. With the number pad up this
                  // sheet fills the screen and dragging it down fights the
                  // scroll view, which left no exit at all from a screen that
                  // is about to move money.
                  Row(
                    children: [
                      const SizedBox(width: 44),
                      Expanded(
                        child: Text('Send money to $_peer',
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 17, fontWeight: FontWeight.w600)),
                      ),
                      SizedBox(
                        width: 44,
                        child: IconButton(
                          icon: const Icon(Icons.close),
                          tooltip: 'Cancel',
                          visualDensity: VisualDensity.compact,
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
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
                          focusNode: _amountFocus,
                          autofocus: !_autofocused,
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
                  const SizedBox(height: 6),
                  // The number pad has no Done or Return key, so this is the
                  // only obvious way to put it away. Tapping the background
                  // also works, but nothing on screen says so.
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text('CAD',
                          style: TextStyle(color: Colors.grey, fontSize: 13)),
                      if (_amountFocus.hasFocus) ...[
                        const SizedBox(width: 12),
                        // A full-size tap target on purpose: shrink-wrapping
                        // it made the button's hit area smaller than its own
                        // label, so taps landed on nothing.
                        TextButton(
                          onPressed: () => FocusScope.of(context).unfocus(),
                          child: const Text('Done',
                              style: TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.w600)),
                        ),
                      ],
                    ],
                  ),
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
                          _feeRow(context, '$_peer gets', _cents),
                          const SizedBox(height: 6),
                          _feeRow(context, 'Our fee', _feeCents, muted: true),
                          const SizedBox(height: 6),
                          _feeRow(context, 'Card processing', _cardCents,
                              muted: true),
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 8),
                            child: Divider(height: 1),
                          ),
                          _feeRow(context, 'You pay', _totalCents, bold: true),
                          const SizedBox(height: 6),
                          Text(
                            'You cover the fees, so $_peer '
                            'receives the full amount. Money goes straight to '
                            'them — we never hold it.',
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
                      onTap: () =>
                          setState(() => _acknowledged = !_acknowledged),
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
                                '$_peer and cannot be reversed. '
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
                      _tooSmall
                          ? 'Minimum \$${(PaymentEconomics.minimumSendCents / 100).toStringAsFixed(2)}'
                          : !_valid
                              ? 'Enter an amount'
                              : (_acknowledged
                                  ? 'Pay \$${(_totalCents / 100).toStringAsFixed(2)}'
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
