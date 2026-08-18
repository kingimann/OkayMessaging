import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../payments/purchase_outcome.dart';
import '../payments/store_purchases.dart';
import '../relay/relay_config.dart';

/// The app's OWN ad inventory: a user pays to carry one of their own public
/// posts further up the timeline, labelled as an ad.
///
/// Separate from [AdService], which serves AdMob's inventory on the same two
/// public surfaces. That one is somebody else's ad in somebody else's slot;
/// this one is a real post by a real account, which is why it is drawn as a
/// post with a badge rather than as an ad card.
///
/// **Nothing here grants a placement.** The purchase is a consumable IAP and
/// the entitlement is written server-side by the `promote-post` Edge
/// Function, which verifies Apple's signature, refuses a post that is not the
/// caller's, and dedupes the transaction. This store buys, asks the server to
/// record it, and then READS the world-readable view — so what it shows is
/// what every other device sees, never a local optimism.
class PromotionStore extends ChangeNotifier {
  PromotionStore._();
  static final PromotionStore instance = PromotionStore._();

  /// Post ids with a placement running right now, newest purchase first.
  final Set<String> _promoted = {};

  /// Whether the last fetch actually answered. Null means "not asked yet",
  /// which is a different thing from "nothing is promoted" — a timeline must
  /// not draw ad badges it only half knows about.
  bool? _loaded;

  Set<String> get promoted => Set.unmodifiable(_promoted);
  bool get loaded => _loaded == true;

  bool isPromoted(String postId) => _promoted.contains(postId);

  /// Test seam: stands in for the view fetch.
  @visibleForTesting
  static Future<Set<String>?> Function()? debugFetchOverride;

  /// Test seam: stands in for the server call that records a purchase.
  @visibleForTesting
  static Future<DateTime?> Function(String postId, String receipt)?
      debugPromoteOverride;

  SupabaseClient? get _client {
    if (!RelayConfig.isEnabled) return null;
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null; // Supabase not initialised (tests, web preview).
    }
  }

  /// Reads which posts are currently promoted. Served by the ANON key like
  /// the feed itself — a name-only account browsing the timeline still has to
  /// be able to tell an ad from a post, and hiding the label from them would
  /// be the one reader who could not.
  Future<void> refresh() async {
    final override = debugFetchOverride;
    if (override != null) {
      final ids = await override();
      if (ids == null) return;
      _promoted
        ..clear()
        ..addAll(ids);
      _loaded = true;
      notifyListeners();
      return;
    }
    final client = _client;
    if (client == null) return;
    try {
      final rows = await client
          .from('promoted_posts_view')
          .select('post_id')
          .order('created_at', ascending: false);
      _promoted
        ..clear()
        ..addAll([
          for (final r in (rows as List<dynamic>))
            (r as Map)['post_id'] as String? ?? ''
        ]..removeWhere((s) => s.isEmpty));
      _loaded = true;
      notifyListeners();
    } catch (_) {
      // Silent, and deliberately does NOT set _loaded: a timeline that could
      // not ask draws no badges rather than claiming nothing is promoted.
    }
  }

  /// Buys a placement for [postId] at [tier] and records it server-side.
  ///
  /// Returns when the placement runs to, or null when nothing was bought —
  /// the buyer cancelled, the product is not on sale, or the server refused
  /// the receipt. The two are told apart by [lastError], which carries the
  /// server's own word for it rather than one sentence for every failure:
  /// three separate rounds of "it only works on my phone" in this app were
  /// each debugged from a bare `catch` that had already been told why.
  String lastError = '';

  Future<DateTime?> promote(String postId, {required int tier}) async {
    lastError = '';
    final result = await StorePurchases.instance.buyPromotion(tier);
    if (!result.ok) {
      // A cancel is not a failure worth a sentence; anything else is.
      if (result.outcome != PurchaseOutcome.cancelled) {
        lastError = result.outcome == PurchaseOutcome.notOffered
            ? 'That promotion is not on sale yet.'
            : 'The store could not complete the purchase.';
      }
      return null;
    }
    final receipt = result.jws ?? '';
    final override = debugPromoteOverride;
    if (override != null) {
      final until = await override(postId, receipt);
      if (until != null) {
        _promoted.add(postId);
        _loaded = true;
        notifyListeners();
      }
      return until;
    }
    final client = _client;
    if (client == null || receipt.isEmpty) {
      // Charged with nowhere to record it. Say so plainly — this is exactly
      // the case somebody needs to be able to quote at support.
      lastError = 'Paid, but this device could not reach the server to start '
          'the placement. It will not be lost — try again in a moment.';
      return null;
    }
    try {
      final res = await client.functions
          .invoke('promote-post', body: {'postId': postId, 'jws': receipt});
      final data = res.data;
      final until = data is Map ? DateTime.tryParse('${data['until']}') : null;
      if (until == null) {
        lastError = data is Map && data['error'] != null
            ? 'The server said: ${data['error']}'
            : 'The server did not confirm the placement.';
        return null;
      }
      _promoted.add(postId);
      _loaded = true;
      notifyListeners();
      return until;
    } catch (e) {
      lastError = 'Could not reach the server to start the placement.';
      return null;
    }
  }

  /// The timeline with paid placements carried up it.
  ///
  /// **Hoisted to fixed EARLY positions, not sorted to the very top and not
  /// ranked against each other.** One ad at the head of a feed is the whole
  /// screen; several would be the whole session. So a placement is moved to
  /// the [every]-th slot and the ones after it, in the order they already
  /// stood — which means paying more buys more DAYS of being carried, never a
  /// better position than somebody else who paid. There is nothing to outbid.
  ///
  /// A promoted post the reader would not otherwise see is NOT inserted: this
  /// reorders what the timeline already served, so muting, blocking, hiding
  /// reposts and every sanction still decide what is in the list at all. An ad
  /// that could reach past a mute would be worth more than a mute.
  ///
  /// Pure and static, so a test pins exactly where an ad may sit — and where
  /// it may not.
  static List<T> hoist<T>(
    List<T> posts, {
    required bool Function(T) isPromoted,
    int every = 4,
  }) {
    if (posts.length < 2) return List<T>.from(posts);
    final ads = <T>[];
    final rest = <T>[];
    for (final p in posts) {
      (isPromoted(p) ? ads : rest).add(p);
    }
    if (ads.isEmpty) return List<T>.from(posts);
    final out = <T>[];
    var next = 0;
    for (var i = 0; i < rest.length; i++) {
      // The slot BEFORE the i-th ordinary post, so the first ad lands after
      // `every` real posts rather than at the very head.
      if (i > 0 && i % every == 0 && next < ads.length) out.add(ads[next++]);
      out.add(rest[i]);
    }
    // Anything that didn't get a slot still appears, at the end, in order —
    // dropping a placement somebody paid for would be the worse failure.
    out.addAll(ads.skip(next));
    return out;
  }

  @visibleForTesting
  void resetForTest() {
    _promoted.clear();
    _loaded = null;
    lastError = '';
    notifyListeners();
  }
}
