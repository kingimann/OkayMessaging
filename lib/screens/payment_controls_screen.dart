import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'package:flutter/services.dart';

import '../payments/payment_service.dart';
import '../util/phone_format.dart';

/// The one network call this screen makes — reading the controls, and updating
/// them, are the same request. Injectable so the screen can be driven in a test
/// without standing up Supabase; the screen's own logic is unchanged either way.
typedef PaymentControlsApi = Future<PaymentControls> Function({
  String? acceptsFrom,
  bool? paused,
  int? dailySendLimitCents,
  int? maxSendCents,
  String? block,
  String? unblock,
});

/// Who may pay you, what you may send, and the switch that stops all of it.
///
/// Every control here is stored and enforced on the server. A limit the app
/// applies is a limit a modified app ignores, and the point of a limit is that
/// it holds when something has gone wrong.
class PaymentControlsScreen extends StatefulWidget {
  const PaymentControlsScreen({super.key, this.debugControls});

  /// Stands in for [PaymentService.controls] in tests.
  final PaymentControlsApi? debugControls;

  @override
  State<PaymentControlsScreen> createState() => _PaymentControlsScreenState();
}

class _PaymentControlsScreenState extends State<PaymentControlsScreen> {
  PaymentControlsApi get _api =>
      widget.debugControls ?? PaymentService.instance.controls;

  late Future<PaymentControls> _future = _api();
  bool _busy = false;

  Future<void> _update({
    String? acceptsFrom,
    bool? paused,
    int? dailySendLimitCents,
    int? maxSendCents,
    String? block,
    String? unblock,
  }) async {
    setState(() => _busy = true);
    try {
      final next = await _api(
        acceptsFrom: acceptsFrom,
        paused: paused,
        dailySendLimitCents: dailySendLimitCents,
        maxSendCents: maxSendCents,
        block: block,
        unblock: unblock,
      );
      if (!mounted) return;
      // A block body, not an arrow: `() => _future = ...` returns the assigned
      // value, and setState asserts when its callback returns a Future. That
      // assertion was thrown *after* the state was set, so the screen updated
      // and then announced "Could not save that" — every successful save read
      // as a failure until a test drove the screen.
      setState(() {
        _future = Future.value(next);
      });
      // A raise doesn't take, it waits — and the switch coming back where it
      // was, with no explanation, reads as a bug rather than as the rule.
      final delayed = dailySendLimitCents != null && next.pendingDaily != null
          ? next.pendingDaily
          : maxSendCents != null && next.pendingMax != null
              ? next.pendingMax
              : null;
      if (delayed != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('A higher limit starts ${_whenText(delayed.at)}. '
              'Lowering one is immediate.'),
        ));
      }
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
              _PauseCard(
                paused: c.paused,
                onChanged:
                    _busy ? null : (v) => _update(paused: v),
              ),
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
              for (final phone in c.blocked)
                ListTile(
                  leading: const Icon(Icons.block, size: 20),
                  title: Text(formatPhoneForDisplay(phone)),
                  subtitle: const Text('Cannot send you money'),
                  trailing: TextButton(
                    onPressed: _busy ? null : () => _update(unblock: phone),
                    child: const Text('Unblock'),
                  ),
                ),
              ListTile(
                leading: const Icon(Icons.person_off_outlined, size: 20),
                title: const Text('Block someone from paying you'),
                subtitle: const Text(
                    'Refuses one number without closing the door to everyone'),
                onTap: _busy ? null : _blockSomeone,
              ),
              _header('Sending'),
              ListTile(
                title: const Text('Most in one transfer'),
                subtitle: Text(_perSendSubtitle(c)),
                trailing: const Icon(Icons.chevron_right),
                onTap: _busy ? null : () => _pickPerSend(c),
              ),
              ListTile(
                title: const Text('Daily limit'),
                subtitle: Text(_dailySubtitle(c)),
                trailing: const Icon(Icons.chevron_right),
                onTap: _busy ? null : () => _pickLimit(c),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                child: Text(
                  'Limits bound what a phone in someone else\'s hands can '
                  'move, and what one bad afternoon can cost. They are checked '
                  'on the server, so they hold even if the app is not the one '
                  'asking — and raising one waits a day, so whoever is holding '
                  'the phone right now cannot simply raise it and send.',
                  style:
                      TextStyle(fontSize: 12.5, color: AppColors.subtle(context)),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  String _perSendSubtitle(PaymentControls c) {
    final base = c.maxSendCents > 0
        ? 'No single transfer may be over ${_money(c.maxSendCents)}.'
        : 'No cap beyond the daily limit.';
    return '$base${_pendingText(c.pendingMax)}';
  }

  String _dailySubtitle(PaymentControls c) {
    final base = c.dailySendLimitCents > 0
        ? 'At most ${_money(c.dailySendLimitCents)} can leave this account '
            'in 24 hours.'
        : 'No daily cap.';
    return '$base${_pendingText(c.pendingDaily)}';
  }

  Widget _header(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
        child: Text(text.toUpperCase(),
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: AppColors.subtle(context))),
      );

  Future<void> _blockSomeone() async {
    final phone = await showDialog<String>(
      context: context,
      builder: (_) => const _BlockNumberDialog(),
    );
    final digits = (phone ?? '').replaceAll(RegExp(r'\D'), '');
    if (digits.length < 7) {
      // Too short to be anybody. Saying nothing would look like it worked.
      if (mounted && phone != null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('That is not a phone number.')));
      }
      return;
    }
    await _update(block: digits);
  }

  Future<void> _pickLimit(PaymentControls current) async {
    final picked = await _pickAmount(
      title: 'Daily send limit',
      options: const [5000, 10000, 25000, 50000, 100000, 200000],
      selected: current.dailySendLimitCents,
    );
    if (picked != null) await _update(dailySendLimitCents: picked);
  }

  Future<void> _pickPerSend(PaymentControls current) async {
    final picked = await _pickAmount(
      title: 'Most in one transfer',
      options: const [0, 2500, 5000, 10000, 25000, 50000, 100000],
      selected: current.maxSendCents,
    );
    if (picked != null) await _update(maxSendCents: picked);
  }

  Future<int?> _pickAmount({
    required String title,
    required List<int> options,
    required int selected,
  }) =>
      showModalBottomSheet<int>(
        context: context,
        showDragHandle: true,
        // Seven rows plus a title do not fit a small phone in landscape, and a
        // sheet that overflows loses the last option rather than scrolling.
        isScrollControlled: true,
        builder: (sheetContext) => SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                  child: Text(title,
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w700)),
                ),
                for (final cents in options)
                  ListTile(
                    title: Text(_moneyOrNone(cents)),
                    trailing: cents == selected
                        ? const Icon(Icons.check, color: Color(0xFF12B76A))
                        : null,
                    onTap: () => Navigator.pop(sheetContext, cents),
                  ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      );
}

/// Asks for a number to refuse. A widget rather than a `showDialog` closure so
/// the controller is disposed when the dialog leaves the tree — disposing it as
/// soon as `showDialog` returns kills it while the route is still animating out,
/// and the focus scope asserts on the way down.
class _BlockNumberDialog extends StatefulWidget {
  const _BlockNumberDialog();

  @override
  State<_BlockNumberDialog> createState() => _BlockNumberDialogState();
}

class _BlockNumberDialogState extends State<_BlockNumberDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Block a number'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('They will not be able to send you money. This does not '
              'block their messages.'),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            keyboardType: TextInputType.phone,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[\d+\-() ]'))
            ],
            decoration: const InputDecoration(
              labelText: 'Phone number',
              hintText: '+1 (555) 010-0000',
            ),
            onSubmitted: (v) => Navigator.pop(context, v),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('Block'),
        ),
      ],
    );
  }
}

/// The switch that stops everything, given the weight it deserves: it is the
/// one control somebody reaches for while something is going wrong.
class _PauseCard extends StatelessWidget {
  const _PauseCard({required this.paused, required this.onChanged});

  final bool paused;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    const stop = Color(0xFFD92D20);
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      elevation: 0,
      color: paused ? stop.withValues(alpha: 0.08) : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: paused ? stop.withValues(alpha: 0.45) : Colors.grey.shade300,
        ),
      ),
      child: SwitchListTile(
        value: paused,
        onChanged: onChanged,
        activeThumbColor: stop,
        secondary: Icon(paused ? Icons.pause_circle : Icons.pause_circle_outline,
            color: paused ? stop : AppColors.subtle(context)),
        title: Text('Pause all payments',
            style: TextStyle(
                fontWeight: FontWeight.w700, color: paused ? stop : null)),
        subtitle: Text(paused
            ? 'Nothing can be sent or received. Turn this off to resume.'
            : 'Stops sending and receiving in one tap'),
      ),
    );
  }
}

/// "$500", or "No limit" for the zero that means no cap.
String _moneyOrNone(int cents) => cents <= 0 ? 'No limit' : _money(cents);

/// What is waiting, appended to whatever is live. Empty when nothing is.
String _pendingText(PendingLimit? p) {
  if (p == null) return '';
  final when = _whenText(p.at);
  // "No limit starts in 1 day" reads as a sentence about nothing.
  return p.cents <= 0
      ? ' Removing the cap starts $when.'
      : ' ${_money(p.cents)} starts $when.';
}

String _money(int cents) {
  final dollars = cents / 100;
  return dollars == dollars.roundToDouble()
      ? '\$${dollars.toStringAsFixed(0)}'
      : '\$${dollars.toStringAsFixed(2)}';
}

/// How long until [at], in the words someone would use — "in 23 hours", not a
/// timestamp they have to subtract from now.
String _whenText(DateTime at) {
  final left = at.difference(DateTime.now());
  if (left.inMinutes <= 0) return 'now';
  if (left.inMinutes < 60) return 'in ${left.inMinutes} min';
  final hours = (left.inMinutes / 60).round();
  if (hours < 24) return 'in $hours hour${hours == 1 ? '' : 's'}';
  final days = (left.inHours / 24).round();
  return 'in $days day${days == 1 ? '' : 's'}';
}
