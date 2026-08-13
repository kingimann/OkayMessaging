import '../state/feed_store.dart';
import '../state/public_feed_store.dart';
import 'payment_service.dart';

/// One source of money coming in, tallied from what THIS device knows.
class EarningsLine {
  final String source;
  final String detail;
  final int cents;

  /// How many events made the amount — sparks counted, listings sold,
  /// transfers received. Context for the number, not a second number.
  final int count;

  const EarningsLine({
    required this.source,
    required this.detail,
    required this.cents,
    required this.count,
  });
}

/// What the account has earned and from where. Built by [computeEarnings]
/// from local state plus (when the wallet can answer) the payment history —
/// never from anything invented, per the no-fake-data rule.
class Earnings {
  final List<EarningsLine> lines;

  /// Whether the wallet history made it into the tally. When false the
  /// direct-payments line is absent, not zero — absence is the honest shape
  /// for "could not be read".
  final bool paymentsIncluded;

  const Earnings({required this.lines, required this.paymentsIncluded});

  int get totalCents => lines.fold(0, (sum, l) => sum + l.cents);
}

/// Cents as a dollar label: '\$12' when even, '\$12.50' when not.
String moneyLabel(int cents) => cents % 100 == 0
    ? '\$${cents ~/ 100}'
    : '\$${(cents / 100).toStringAsFixed(2)}';

/// Tallies earnings from what the device holds. Pure, so it's testable.
///
/// Three sources, each honest about its provenance:
/// - Sparks on your posts (both feeds) — the tallies the spark events built.
/// - Marketplace sales — YOUR sold listings at their listed price; the
///   handshake records the ask, not what changed hands, and the screen
///   says so.
/// - Payments received — completed transfers from the wallet history,
///   minus sparks, which are already counted above (a spark rides a
///   transfer, so summing both would count the same dollar twice).
Earnings computeEarnings({
  required List<FeedPost> serverPosts,
  required List<PublicPost> publicPosts,
  required String myUsername,
  List<PaymentRecord>? history,
}) {
  final me = myUsername.toLowerCase();
  bool mine(FeedPost p) =>
      p.authorUsername == 'you' || p.authorUsername.toLowerCase() == me;

  var sparkCents = 0;
  var sparkCount = 0;
  var saleCents = 0;
  var saleCount = 0;
  for (final p in serverPosts) {
    if (!mine(p)) continue;
    if (p.sparkCents > 0) {
      sparkCents += p.sparkCents;
      sparkCount += p.sparks;
    }
    if (p.isListing && p.listingSold && (p.priceCents ?? 0) > 0) {
      saleCents += p.priceCents!;
      saleCount++;
    }
  }
  for (final p in publicPosts) {
    if (p.authorUsername.toLowerCase() != me || me.isEmpty) continue;
    if (p.sparkCents > 0) {
      sparkCents += p.sparkCents;
      sparkCount += p.sparkCount;
    }
  }

  var receivedCents = 0;
  var receivedCount = 0;
  for (final r in history ?? const <PaymentRecord>[]) {
    if (r.sent || r.isPayout || !r.isComplete || r.isTip) continue;
    receivedCents += r.amountCents;
    receivedCount++;
  }

  return Earnings(
    paymentsIncluded: history != null,
    lines: [
      EarningsLine(
        source: 'Sparks on your posts',
        detail: 'Tips from readers, on both feeds',
        cents: sparkCents,
        count: sparkCount,
      ),
      EarningsLine(
        source: 'Marketplace sales',
        detail: 'Sold listings, at their listed price',
        cents: saleCents,
        count: saleCount,
      ),
      if (history != null)
        EarningsLine(
          source: 'Payments received',
          detail: 'Money people sent you directly',
          cents: receivedCents,
          count: receivedCount,
        ),
    ],
  );
}
