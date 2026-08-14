import 'package:flutter/material.dart';

import '../app_state.dart';
import '../payments/earnings.dart';
import '../payments/payment_service.dart';
import '../state/feed_store.dart';
import '../state/public_feed_store.dart';
import '../theme/app_theme.dart';

/// What this account has earned and from where — sparks, marketplace sales,
/// and (when the wallet can answer) payments received. Tallied from what the
/// device knows; nothing here is estimated or invented.
class EarningsScreen extends StatefulWidget {
  /// True when this is a tab of [MoneyScreen]: the list only, without a
  /// scaffold or app bar of its own.
  final bool embedded;

  const EarningsScreen({super.key, this.embedded = false});

  /// Tests stand in for the wallet here — the real history needs a session
  /// and a deployed Edge Function, and the suite runs with neither.
  static Future<List<PaymentRecord>> Function()? debugHistoryOverride;

  @override
  State<EarningsScreen> createState() => _EarningsScreenState();
}

class _EarningsScreenState extends State<EarningsScreen> {
  // null while loading or when the wallet can't answer — the payments line
  // is then absent rather than a zero that reads as "nobody paid you".
  List<PaymentRecord>? _history;
  bool _historySettled = false;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    List<PaymentRecord>? loaded;
    try {
      final fn = EarningsScreen.debugHistoryOverride;
      loaded = fn != null ? await fn() : await PaymentService.instance.history();
    } catch (_) {
      loaded = null;
    }
    if (!mounted) return;
    setState(() {
      _history = loaded;
      _historySettled = true;
    });
  }

  IconData _iconFor(String source) => switch (source) {
        'Sparks on your posts' => Icons.bolt_outlined,
        'Marketplace sales' => Icons.storefront_outlined,
        _ => Icons.call_received,
      };

  @override
  Widget build(BuildContext context) {
    final body = ListenableBuilder(
        listenable: Listenable.merge(
            [FeedStore.instance, PublicFeedStore.instance]),
        builder: (context, _) {
          final me = AppState.profile.value.username;
          final earnings = computeEarnings(
            serverPosts: FeedStore.instance.allPosts,
            publicPosts: PublicFeedStore.instance.posts,
            myUsername: me.isEmpty ? 'you' : me,
            history: _history,
          );
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // The one number the screen exists to answer.
              Container(
                padding: const EdgeInsets.symmetric(vertical: 24),
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .primary
                      .withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  children: [
                    Text(moneyLabel(earnings.totalCents),
                        style: const TextStyle(
                            fontSize: 34, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 4),
                    Text('earned so far',
                        style: TextStyle(
                            fontSize: 13, color: AppColors.subtle(context))),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Text('WHERE IT CAME FROM',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.6,
                      color: AppColors.subtle(context))),
              const SizedBox(height: 4),
              for (final line in earnings.lines)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(_iconFor(line.source)),
                  title: Text(line.source),
                  subtitle: Text(line.count == 0
                      ? line.detail
                      : '${line.detail} · ${line.count}'),
                  trailing: Text(moneyLabel(line.cents),
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700)),
                ),
              if (_historySettled && !earnings.paymentsIncluded)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Payments received couldn\'t be read right now — they '
                    'need the wallet, which needs a signed-in session.',
                    style: TextStyle(
                        fontSize: 12.5, color: AppColors.subtle(context)),
                  ),
                ),
              const SizedBox(height: 16),
              Text(
                'Counted from this device: spark tips on your posts, your '
                'sold listings at the price they listed for, and completed '
                'transfers sent to you. Sparks already counted above are '
                'left out of the payments line, so nothing counts twice.',
                style: TextStyle(
                    fontSize: 12.5, color: AppColors.subtle(context)),
              ),
            ],
          );
        },
      );
    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(title: const Text('Earnings')),
      body: body,
    );
  }
}
