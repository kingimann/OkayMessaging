import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../payments/storage_economics.dart';
import 'pricing_store.dart';

/// One purchasable storage size. The App Store can only sell **fixed** price
/// points, so "choose your own amount" is a ladder of real products the picker
/// snaps to — not a free-form number.
class StoragePlan {
  /// Gigabytes this plan grants.
  final int gb;

  /// Monthly price in cents, before Apple's cut.
  final int priceCents;

  const StoragePlan(this.gb, this.priceCents);

  /// No plan at all — there is no free tier, so this is the "not subscribed"
  /// state rather than a tier anyone is on.
  bool get isNone => priceCents == 0;
  String get name => isNone ? 'No plan' : '$gb GB';
  int get quotaBytes => gb * 1024 * 1024 * 1024;

  String get priceLabel {
    if (isNone) return 'Not subscribed';
    final dollars = priceCents / 100;
    final text = priceCents % 100 == 0
        ? dollars.toStringAsFixed(0)
        : dollars.toStringAsFixed(2);
    return '\$$text/mo';
  }
}

/// Paid chat-backup storage, sold by the gigabyte.
///
/// **This only ever holds chats.** Servers, feed posts and follows are
/// communal — they sync to everyone in a server for free and never count
/// against anyone's quota.
///
/// Cloud backup is paid only — there is no free allowance. Every stored GB
/// costs real money to hold and serve (see [StorageEconomics]), and giving
/// some away meant every signed-up account carried a bill whether or not it
/// ever paid anything. A user picks how much space they want, up to [maxGb],
/// and pays monthly through the App Store. Every
/// step on the ladder is priced above its own Supabase cost (see
/// [StorageEconomics]), so selling more space is always profitable — including
/// once the project outgrows the 100 GB the Pro plan includes and Supabase
/// starts billing overage.
class StorageStore extends ChangeNotifier {
  StorageStore._();
  static final StorageStore instance = StorageStore._();

  static const _kGb = 'cloud_storage_gb';
  static const _kTierLegacy = 'cloud_storage_tier'; // pre-custom-GB builds
  static const _kActiveUntil = 'cloud_storage_active_until';
  static const _kUsedBytes = 'cloud_storage_used_bytes';

  static const int _bytesPerGb = 1024 * 1024 * 1024;

  /// Free allowance. Zero: backup requires a subscription.
  ///
  /// Kept as a named constant rather than deleted, because "how much do you
  /// get without paying" is a real question the UI and the economics both ask,
  /// and the answer wants to be stated in one place.
  static const int freeGb = 0;

  /// The free CHAT-BACKUP allowance, in bytes.
  ///
  /// Separate from [freeGb] and deliberately not a round gigabyte, because
  /// this is not a free media locker: [fits] is only ever asked about the
  /// chat backup — grep-verified, nothing else in the app calls it — and a
  /// chat backup is TEXT. 250 MB is a lifetime of conversation for almost
  /// anybody.
  ///
  /// **Why it exists at all.** Chats were excluded from the free backup by a
  /// key decision (the phone-derived key is not a secret), and then excluded
  /// a second time by having nowhere to go: with no free allowance at all,
  /// [fits] refused every payload, so setting a passphrase made a chat
  /// backup *possible* and never *working*. A free tier is what makes
  /// "my conversations survive a new phone" true for an ordinary account.
  ///
  /// **It costs almost nothing, because an allowance is a ceiling and not a
  /// bill.** Storage is charged on bytes actually held (\$0.0213/GB-month),
  /// so an unused ceiling costs zero and a fully-used one costs about half a
  /// cent per account per month. The paid ladder is untouched and still
  /// starts where it did — what is given away here is text, which is not
  /// what anybody buys a storage plan for.
  static const int freeBytes = 250 * 1024 * 1024;

  /// [freeBytes] as a plain size for copy that names it, so the sentence and
  /// the ceiling can never drift apart.
  static String get freeAllowanceLabel =>
      '${freeBytes ~/ (1024 * 1024)} MB';

  /// The most one account may buy. Caps a single user's claim on the
  /// project's capacity, and keeps "no unlimited" true.
  static const int maxGb = 100;

  /// Ladder granularity: sizes are sold in this step, so the picker snaps.
  static const int stepGb = 10;

  /// The purchasable sizes: 10, 20, … up to [maxGb].
  static List<int> get sizes =>
      [for (var gb = stepGb; gb <= maxGb; gb += stepGb) gb];

  /// Price for [gb], in cents — the owner's published price for that exact
  /// size when there is one, else the per-GB retail rate landed on a normal
  /// App Store price point (x.99).
  ///
  /// Per-size prices are what make matching App Store Connect possible at
  /// all: one rate locks all ten sizes into a fixed relationship, so a rate
  /// chosen to match 10 GB necessarily mismatches the rest. This is still the
  /// figure shown only where StoreKit has no price to give (web, test mode,
  /// the first frame) — the real charge always wins over it.
  static int priceCentsFor(int gb) =>
      PricingStore.instance.storageCentsFor(gb);

  static StoragePlan planForGb(int gb) => StoragePlan(gb, priceCentsFor(gb));

  /// Every purchasable size, cheapest first. No free entry — there isn't one.
  static List<StoragePlan> get plans => [
        for (final gb in sizes) planForGb(gb),
      ];

  /// A single paid month.
  static const Duration period = Duration(days: 30);

  /// Gigabytes the user has bought (0 = free tier only).
  int _purchasedGb = 0;
  DateTime? _activeUntil;
  int _usedBytes = 0;

  /// The size the user paid for, even if the subscription has since lapsed —
  /// used to show "renew" rather than "subscribe".
  int get selectedGb => _purchasedGb;

  /// True while a paid size is bought and unexpired.
  bool get isPaid {
    if (_purchasedGb <= 0) return false;
    final until = _activeUntil;
    return until != null && until.isAfter(DateTime.now());
  }

  /// Gigabytes actually available right now: the purchase if it's live, else
  /// the free allowance.
  int get activeGb => isPaid ? _purchasedGb : freeGb;

  /// The plan in force right now.
  StoragePlan get plan =>
      isPaid ? planForGb(_purchasedGb) : const StoragePlan(freeGb, 0);

  DateTime? get activeUntil => _activeUntil;

  int get daysLeft {
    final until = _activeUntil;
    if (until == null || !isPaid) return 0;
    final left = until.difference(DateTime.now());
    return left.isNegative ? 0 : left.inDays;
  }

  /// What may be stored right now: the paid size, or the free allowance —
  /// whichever is larger, so buying a plan can never leave somebody with
  /// less room than they had for nothing.
  int get quotaBytes {
    final paid = activeGb * _bytesPerGb;
    return paid > freeBytes ? paid : freeBytes;
  }
  int get usedBytes => _usedBytes;

  int get availableBytes {
    final left = quotaBytes - _usedBytes;
    return left < 0 ? 0 : left;
  }

  double get usedFraction {
    if (quotaBytes <= 0) return 0;
    final f = _usedBytes / quotaBytes;
    return f < 0 ? 0 : (f > 1 ? 1 : f);
  }

  /// Whether a chat backup of [bytes] fits under the current ceiling.
  bool fits(int bytes) => bytes <= quotaBytes;

  /// At or over the ceiling — nothing more can be backed up until they free
  /// space or buy more.
  ///
  /// Having no plan is not "full": nothing has been stored and nothing needs
  /// clearing out. Without this guard an account that had never backed
  /// anything up was greeted with a red "your 0 B of storage is full".
  bool get isFull => quotaBytes > 0 && _usedBytes >= quotaBytes;

  /// Within the last 10% of a plan — worth nudging. Meaningless without one.
  bool get nearLimit => quotaBytes > 0 && usedFraction >= 0.9;

  /// The smallest purchasable size that would hold [bytes], or null when even
  /// [maxGb] wouldn't (there is no unlimited).
  StoragePlan? smallestPlanFor(int bytes) {
    for (final gb in sizes) {
      if (bytes <= gb * _bytesPerGb) return planForGb(gb);
    }
    return null;
  }

  /// The next size up from what's active, or null at the ceiling.
  StoragePlan? get nextSizeUp {
    for (final gb in sizes) {
      if (gb > activeGb) return planForGb(gb);
    }
    return null;
  }

  String get usedLabel => formatBytes(_usedBytes);
  String get availableLabel => formatBytes(availableBytes);
  String get quotaLabel => formatBytes(quotaBytes);

  /// Human-readable byte size: "0 B", "2.4 KB", "1.1 MB", "5 GB".
  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    const units = ['KB', 'MB', 'GB', 'TB'];
    double value = bytes / 1024;
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    final rounded = value >= 100 || value == value.roundToDouble()
        ? value.round().toString()
        : value.toStringAsFixed(1);
    return '$rounded ${units[unit]}';
  }

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _purchasedGb = prefs.getInt(_kGb) ?? _migratedLegacyGb(prefs);
      final ms = prefs.getInt(_kActiveUntil);
      if (ms != null) {
        _activeUntil = DateTime.fromMillisecondsSinceEpoch(ms);
      }
      _usedBytes = prefs.getInt(_kUsedBytes) ?? 0;
      notifyListeners();
    } catch (_) {}
  }

  /// Builds before custom sizes stored a named tier. Carry those purchases
  /// across rather than silently dropping someone to the free allowance.
  int _migratedLegacyGb(SharedPreferences prefs) => switch (
          prefs.getString(_kTierLegacy)) {
        'personal' => 20, // nearest ladder step at or above the old 15 GB
        'pro' || 'plus' => 100,
        'studio' => maxGb,
        _ => 0,
      };

  /// Buys (or renews) [gb] of storage, adding one month. Paid months stack on
  /// any time remaining. Sizes are clamped to the ladder's ceiling.
  Future<void> subscribe(int gb) async {
    if (gb <= 0) {
      await cancel();
      return;
    }
    _purchasedGb = gb > maxGb ? maxGb : gb;
    final now = DateTime.now();
    final base = (_activeUntil != null && _activeUntil!.isAfter(now))
        ? _activeUntil!
        : now;
    _activeUntil = base.add(period);
    await _persist();
    notifyListeners();
  }

  /// Adopts the server's view of the subscription.
  ///
  /// Apple renews (and cancels, and refunds) whether or not the app is open,
  /// so `iap-status` — not a local +30 days — is what actually decides. The
  /// local copy is kept only so the screens have something to show before the
  /// first round trip and while offline; a null [expiresAt] with [active]
  /// true means Apple gave no date, so the local period stands in.
  Future<void> applyServerEntitlement({
    required bool active,
    required int gb,
    DateTime? expiresAt,
  }) async {
    if (!active || gb <= 0) {
      // Only clear a paid plan the server denies — never wipe one just
      // because the call came back empty (that path returns without calling).
      _purchasedGb = 0;
      _activeUntil = null;
    } else {
      _purchasedGb = gb > maxGb ? maxGb : gb;
      _activeUntil = expiresAt ?? DateTime.now().add(period);
    }
    await _persist();
    notifyListeners();
  }

  /// Drops back to the free allowance immediately.
  Future<void> cancel() async {
    _purchasedGb = 0;
    _activeUntil = null;
    await _persist();
    notifyListeners();
  }

  /// Records how big the latest chat backup is. Called after every chat upload.
  Future<void> setUsedBytes(int bytes) async {
    if (bytes == _usedBytes) return;
    _usedBytes = bytes < 0 ? 0 : bytes;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kUsedBytes, _usedBytes);
    } catch (_) {}
    notifyListeners();
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kGb, _purchasedGb);
      await prefs.remove(_kTierLegacy);
      final until = _activeUntil;
      if (until == null) {
        await prefs.remove(_kActiveUntil);
      } else {
        await prefs.setInt(_kActiveUntil, until.millisecondsSinceEpoch);
      }
    } catch (_) {}
  }

  @visibleForTesting
  void debugSubscribe(int gb, {Duration length = period}) {
    _purchasedGb = gb;
    _activeUntil = gb <= 0 ? null : DateTime.now().add(length);
    notifyListeners();
  }

  @visibleForTesting
  void resetForTest() {
    _purchasedGb = 0;
    _activeUntil = null;
    _usedBytes = 0;
  }
}
