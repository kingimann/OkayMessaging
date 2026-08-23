import 'package:flutter/foundation.dart';

import '../state/pricing_store.dart';
import '../state/storage_store.dart';
import 'apple_iap.dart';
import 'purchase_outcome.dart';
import 'store_prices.dart';
import 'iap_entitlement.dart';
import 'payment_service.dart';

/// Digital purchases that MUST go through the platform store (Apple / Google),
/// not Stripe: the cloud-storage subscription and tipping the developer. Stripe
/// stays reserved for real-world peer-to-peer transfers ([PaymentService]).
///
/// Every purchase resolves to a simple bool. In payments test mode it's
/// simulated (so the flows can be exercised anywhere); otherwise it drives the
/// real store sheet via [AppleIap]. The product IDs below must be created in
/// App Store Connect / Play Console before real charges can happen.
class StorePurchases {
  StorePurchases._();
  static final StorePurchases instance = StorePurchases._();

  static const _prefix = 'com.okaymessaging';

  /// **IN-APP PURCHASES ARE OFF (2026-08-23, the owner's call — to submit
  /// without them).** Flip this to true to put the shop back; nothing else
  /// has to change, and every gate below reads this one constant.
  ///
  /// **Why a hard OFF rather than leaving the products absent.** App Store
  /// Connect not carrying a product and the app not offering one look the
  /// same from the outside and are not: the first is a purchase button that
  /// opens a sheet saying the item cannot be bought, which is a
  /// non-functional purchase and a rejection under Guideline 2.1. Nothing
  /// may LEAD to a charge, so the surfaces go rather than being disabled in
  /// place.
  ///
  /// **It is checked in two places on purpose.** Every `buy…` below refuses
  /// before it can reach StoreKit — the backstop, so a call site added later
  /// still cannot charge — and each screen hides its own way in, so nobody
  /// is shown a control that only refuses. The backstop alone would be a
  /// shop full of dead buttons; the hiding alone would be one modified
  /// client away from a charge.
  ///
  /// **The refusal is checked BEFORE test mode**, or payments-test mode
  /// would go on answering "bought" for a purchase the app no longer offers.
  ///
  /// What is deliberately NOT affected: Stripe. Peer-to-peer transfers, the
  /// wallet and marketplace payments are real-world money between two
  /// people, which Apple has never required to go through IAP, and none of
  /// them touches this class.
  static const bool enabledByDefault = false;

  /// Test hook. The sixteen tests that exercise the shop set this rather than
  /// being deleted: they are the coverage that matters the day the flag goes
  /// back, and a shop nobody tests is how it comes back broken. Production
  /// never touches it, so what ships is [enabledByDefault] and nothing else.
  @visibleForTesting
  static bool? debugEnabledOverride;

  /// Whether the app offers in-app purchases here.
  static bool get enabled => debugEnabledOverride ?? enabledByDefault;

  /// The one refusal, so the six purchase paths cannot word it differently.
  static const PurchaseResult _off =
      PurchaseResult(PurchaseOutcome.notOffered);

  /// Auto-renewable storage subscription, one product per purchasable size.
  /// Apple only sells fixed price points, so the size ladder *is* the product
  /// list — `…storage.gb30.monthly` for 30 GB, and so on.
  static String storageProductId(int gb) =>
      gb <= 0 ? '' : '$_prefix.storage.gb$gb.monthly';

  /// A creator-subscription month, one product per price tier. Deliberately a
  /// CONSUMABLE, not an auto-renewable subscription: a reader may subscribe to
  /// many creators at the same tier, and Apple treats a second purchase of one
  /// auto-renewable SKU as renewing the first — so it could never express "a
  /// month of THIS creator". A consumable can be bought over and over, and the
  /// app tracks which creator each month bought (a 30-day pass you renew, the
  /// same shape as the storage pass). Tier index matches
  /// [PricingStore.instance.tierCents].
  static String creatorSubProductId(int tier) =>
      (tier < 0 || tier >= 4) ? '' : '$_prefix.creatorsub.tier$tier.monthly';

  /// Buys one month of a creator's subscription at [tier]. Returns the store
  /// result; granting the entitlement is the caller's job (CreatorSubStore),
  /// because — like a tip — a consumable carries no entitlement of its own.
  Future<PurchaseResult> buyCreatorSub(int tier) async {
    if (!enabled) return _off;
    final id = creatorSubProductId(tier);
    if (id.isEmpty) {
      return const PurchaseResult(PurchaseOutcome.notOffered);
    }
    if (_maySimulate) {
      await Future<void>.delayed(const Duration(milliseconds: 900));
      return const PurchaseResult.bought('test-mode');
    }
    return AppleIap.buy(id, consumable: true);
  }

  /// The IAP product for a month of a PAID SERVER's membership at [tier] — a
  /// consumable, the same shape as a creator sub, so the same four price
  /// levels map to four products. A separate SKU family from creatorsub so a
  /// membership month and a creator month can't be confused for one another.
  static String communitySubProductId(int tier) =>
      (tier < 0 || tier >= 4) ? '' : '$_prefix.communitysub.tier$tier.monthly';

  /// Buys one month of a paid server's membership at [tier]. Returns the store
  /// result; granting the local pass is the caller's job (CommunitySubStore).
  Future<PurchaseResult> buyCommunitySub(int tier) async {
    if (!enabled) return _off;
    final id = communitySubProductId(tier);
    if (id.isEmpty) {
      return const PurchaseResult(PurchaseOutcome.notOffered);
    }
    if (_maySimulate) {
      await Future<void>.delayed(const Duration(milliseconds: 900));
      return const PurchaseResult.bought('test-mode');
    }
    return AppleIap.buy(id, consumable: true);
  }

  /// How many days each promotion tier buys. The SERVER is the authority
  /// (`promote-post` reads the same ladder off the product id); this copy is
  /// what the sheet shows before the purchase.
  ///
  /// Paying more buys more DAYS, never a better slot. There is deliberately
  /// no auction: nothing to outbid means nothing to game, and the serving
  /// side never reads what was spent.
  static const List<int> promotionDays = [3, 7, 14, 30];

  /// The IAP product for promoting one post at [tier] — a consumable, the
  /// same shape as a creator sub, and its own SKU family so a week of reach
  /// can never be confused for a month of somebody's paid feed.
  static String promotionProductId(int tier) =>
      (tier < 0 || tier >= 4) ? '' : '$_prefix.promote.tier$tier.week';

  /// Buys one placement at [tier]. Returns the store result; starting the
  /// placement is the caller's job (PromotionStore), and it goes through the
  /// server — a consumable carries no entitlement of its own, and this app
  /// never lets a client grant itself reach.
  Future<PurchaseResult> buyPromotion(int tier) async {
    if (!enabled) return _off;
    final id = promotionProductId(tier);
    if (id.isEmpty) {
      return const PurchaseResult(PurchaseOutcome.notOffered);
    }
    if (_maySimulate) {
      await Future<void>.delayed(const Duration(milliseconds: 900));
      return const PurchaseResult.bought('test-mode');
    }
    return AppleIap.buy(id, consumable: true);
  }

  /// Every product id the Okay AI pass might be filed under in App Store
  /// Connect, owner's answer first.
  ///
  /// There are two because the app and the store disagreed about the name and
  /// a wrong guess is invisible: the store simply says it has never heard of
  /// the product, no price ever loads, and the card sits there looking broken
  /// with nothing on screen saying why. Both are asked for in the SAME batch
  /// query the app already makes, so the cost is nothing and whichever one
  /// really exists is the one that answers.
  ///
  /// SETTLED 2026-08-21, the owner's call: the reversed id is the one App
  /// Store Connect actually carries, so it leads. The bare `okay_ai_pro`
  /// stays behind it rather than being deleted — it costs nothing (both ride
  /// the same batch query) and it is what an older build asked for, so a
  /// device that answers only the old name still gets a price instead of a
  /// card that looks broken with nothing on screen saying why.
  static const List<String> aiPassProductIds = [
    '$_prefix.okayai.pro.monthly',
    'okay_ai_pro',
  ];

  /// The AI pass id the STORE has confirmed, or the owner's stated one until
  /// it answers. Resolving through the store rather than a constant is what
  /// makes a mismatch self-correcting instead of silent.
  static String get aiPassProductId {
    for (final id in aiPassProductIds) {
      if (StorePrices.instance.priceFor(id) != null) return id;
    }
    return aiPassProductIds.first;
  }

  /// Buys one month of unlimited Okay AI. Test mode simulates it.
  Future<PurchaseResult> buyAiPass() async {
    if (!enabled) return _off;
    if (_maySimulate) {
      await Future<void>.delayed(const Duration(milliseconds: 900));
      return const PurchaseResult.bought('test-mode');
    }
    return AppleIap.buy(aiPassProductId, consumable: true);
  }

  /// Fixed consumable tip products. Apple doesn't allow arbitrary amounts, so
  /// support is a small set of set prices.
  static const List<({int cents, String emoji, String label, String id})>
      tipProducts = [
    (cents: 299, emoji: '☕', label: 'Coffee', id: '$_prefix.tip.coffee'),
    (cents: 599, emoji: '🍩', label: 'Snack', id: '$_prefix.tip.snack'),
    (cents: 1099, emoji: '🍕', label: 'Lunch', id: '$_prefix.tip.lunch'),
    (cents: 2499, emoji: '🎉', label: 'Generous', id: '$_prefix.tip.generous'),
  ];

  /// The assumed amount for a tip — the owner's published figure when there
  /// is one, else the built-in. Like every other number here it is only what
  /// shows where StoreKit has no price; the store's own always wins.
  static int tipCentsFor(String productId, int fallback) =>
      PricingStore.instance.tipCents(productId, fallback);

  /// Whether a purchase may be SIMULATED instead of charged.
  ///
  /// Test mode alone is no longer enough, and that is the point: it used to
  /// be, so every `buy…` below answered "bought" without StoreKit ever
  /// running. On a real phone that is an app that appears to sell things
  /// while never opening an App Store sheet — which is exactly what a
  /// reviewer reports as being unable to find the in-app purchases, and what
  /// Guideline 3.1.1 is about.
  ///
  /// It was worse than a developer convenience, because the App Review demo
  /// account was PINNED to test mode: the one person who had to see a real
  /// purchase sheet was the one person who could never reach one. That pin
  /// is gone with the account's special-casing.
  ///
  /// [AppleIap.hasRealStore] is dart:io's own Platform check — false under
  /// `flutter test` (a linux host) and on web, true on a device — so the
  /// suite keeps its simulation and a phone can never fake a charge.
  bool get _maySimulate =>
      PaymentService.instance.testMode.value && !AppleIap.hasRealStore;

  /// Whether store purchases can be made here: test mode works everywhere;
  /// the real store is mobile-only.
  ///
  /// Under `flutter test` AppleIap.isSupported is TRUE (flutter_test reports
  /// android), so the no-store case — the web build — cannot otherwise be
  /// reached by a test, and it is the case that was rendering "$0.00".
  bool get isSupported =>
      (!enabled || debugNoStoreOverride == true)
          ? false
          // The raw flag, not [_maySimulate]: this only decides whether the
          // UI renders a store at all, and test mode has always been allowed
          // to make one appear off-device. Nothing here charges anything.
          : (PaymentService.instance.testMode.value || AppleIap.isSupported);

  @visibleForTesting
  static bool? debugNoStoreOverride;

  /// Buys (or renews) the storage subscription for [gb]. Returns true when the
  /// purchase completes.
  ///
  /// What the purchase *granted* is not decided here: StoreKit's signed
  /// transaction goes to `iap-validate`, and the entitlement that comes back
  /// is what the app honours. Apple renews monthly on its own, so the device
  /// can't be the source of truth.
  Future<PurchaseResult> buyStorage(int gb) async {
    if (!enabled) return _off;
    final id = storageProductId(gb);
    if (id.isEmpty) {
      return const PurchaseResult(PurchaseOutcome.notOffered);
    }
    if (_maySimulate) {
      await Future<void>.delayed(const Duration(milliseconds: 900));
      return const PurchaseResult.bought('test-mode');
    }
    final result = await AppleIap.buy(id, consumable: false);
    if (!result.ok) return result;
    // AppleIap.onTransaction has already forwarded this for validation; the
    // await is so the caller sees the entitlement before the screen redraws.
    await IapEntitlement.instance.validate(result.jws!);
    return result;
  }

  /// Sends a tip to the developer via a consumable in-app purchase.
  Future<PurchaseResult> tip(String productId) async {
    if (!enabled) return _off;
    if (_maySimulate) {
      await Future<void>.delayed(const Duration(milliseconds: 900));
      return const PurchaseResult.bought('test-mode');
    }
    return AppleIap.buy(productId, consumable: true);
  }

  /// Replays this Apple ID's past purchases through the purchase stream, so
  /// [AppleIap.onTransaction] revalidates them and the entitlement comes back.
  /// A no-op where a purchase would only be simulated, and anywhere there is
  /// no store. On a real device it always runs: Apple requires a working
  /// restore wherever purchases are sold, and test mode used to switch it off
  /// there too.
  Future<void> restorePurchases() async {
    // Nothing was ever sold here, so there is nothing to replay — and
    // Apple's requirement to offer a restore applies "wherever purchases
    // are sold", which this build does not.
    if (!enabled) return;
    if (_maySimulate || !AppleIap.isSupported) return;
    await AppleIap.init();
    await AppleIap.restore();
  }

  /// Asks the store which tip products it will sell here.
  Future<StoreQueryResult> checkTips() =>
      AppleIap.query({for (final t in tipProducts) t.id});

  /// One sellable product, as the app understands it: what it is, which
  /// family it belongs to, and the price the code assumes. This is the
  /// checklist App Store Connect gets measured against — a product created
  /// under a different id is a different product, and the only way to see
  /// that is to compare the store's answer against a written-down list.
  /// Pure, so a test can hold the catalogue to the ids the app actually buys.
  static List<({String id, String group, String label, int cents})>
      catalogue() => [
            for (final gb in StorageStore.sizes)
              (
                id: storageProductId(gb),
                group: 'Cloud storage',
                label: '$gb GB',
                cents: StorageStore.priceCentsFor(gb),
              ),
            for (final t in tipProducts)
              (
                id: t.id,
                group: 'Developer tips',
                label: t.label,
                cents: tipCentsFor(t.id, t.cents),
              ),
            for (var i = 0; i < 4; i++)
              (
                id: creatorSubProductId(i),
                group: 'Creator subscriptions',
                label: 'Tier ${i + 1}',
                cents: PricingStore.instance.tierCents[i],
              ),
            for (var i = 0; i < 4; i++)
              (
                id: communitySubProductId(i),
                group: 'Paid server memberships',
                label: 'Tier ${i + 1}',
                cents: PricingStore.instance.tierCents[i],
              ),
            for (var i = 0; i < 4; i++)
              (
                id: promotionProductId(i),
                group: 'Promoted posts',
                label: '${promotionDays[i]} days',
                cents: PricingStore.instance.tierCents[i],
              ),
            // The one product the app never prices — whatever App Store
            // Connect charges is the charge, so there is nothing to compare.
            // BOTH candidates, so this screen is where the naming gets
            // settled: exactly one of them should come back on sale.
            for (final id in aiPassProductIds)
              (
                id: id,
                group: 'Okay AI',
                label: 'Unlimited pass',
                cents: 0,
              ),
          ];

  /// Asks the store about EVERY product in [catalogue], not just the tips —
  /// the answer to "I added some products in App Store Connect, did they
  /// land?", which nothing outside a real device can answer.
  Future<StoreQueryResult> checkAll() =>
      AppleIap.query({for (final p in catalogue()) p.id});

  /// Turns the store's answer into the sentence that names the broken link.
  /// Pure, because "products exist in App Store Connect but the store says
  /// not on sale" has four different causes and a failed purchase alone
  /// cannot tell them apart.
  static String tipsCheckVerdict(StoreQueryResult r) {
    if (!r.storeReachable) {
      return 'The App Store isn\'t reachable from here. On an iPhone, check '
          'that this device is signed in to the App Store; anywhere else '
          'there is no store to ask.';
    }
    if (r.notOffered.isEmpty) {
      return 'Every tip product is on sale, at the store\'s own prices above. '
          'If sending a tip still fails, the store sheet itself is refusing — '
          'that is a different error and it will say so.';
    }
    if (r.onSale.isEmpty) {
      return 'The App Store has never heard of ANY tip product, which points '
          'at the account rather than the products. In App Store Connect '
          'check, in order:\n'
          '1. Agreements → the Paid Applications agreement must be Active '
          '(banking and tax complete) — every in-app product is invisible '
          'until it is.\n'
          '2. Each product\'s status must be "Ready to Submit" — "Missing '
          'Metadata" means a name, price or description is still blank.\n'
          '3. Newly created products can take a few hours to reach the '
          'store.\n'
          '4. The products must be under this app (com.okaymessaging), not '
          'another app record.';
    }
    return 'The store offers some tips but has never heard of: '
        '${r.notOffered.join(', ')}. Those exact product IDs must exist in '
        'App Store Connect — a product created under a different ID is a '
        'different product.';
  }
}
