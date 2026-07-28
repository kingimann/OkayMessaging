import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../payments/storage_economics.dart';

/// One purchasable storage size. The App Store can only sell **fixed** price
/// points, so "choose your own amount" is a ladder of real products the picker
/// snaps to — not a free-form number.
class StoragePlan {
  /// Gigabytes this plan grants.
  final int gb;

  /// Monthly price in cents, before Apple's cut.
  final int priceCents;

  const StoragePlan(this.gb, this.priceCents);

  bool get isFree => priceCents == 0;
  String get name => isFree ? 'Free' : '$gb GB';
  int get quotaBytes => gb * 1024 * 1024 * 1024;

  String get priceLabel {
    if (isFree) return 'Free';
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
/// Everyone gets [freeGb] for nothing. Above that a user picks how much space
/// they want, up to [maxGb], and pays monthly through the App Store. Every
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

  /// Free allowance, no purchase required.
  static const int freeGb = 2;

  /// The most one account may buy. Caps a single user's claim on the
  /// project's capacity, and keeps "no unlimited" true.
  static const int maxGb = 100;

  /// Ladder granularity: sizes are sold in this step, so the picker snaps.
  static const int stepGb = 10;

  /// The purchasable sizes: 10, 20, … up to [maxGb].
  static List<int> get sizes =>
      [for (var gb = stepGb; gb <= maxGb; gb += stepGb) gb];

  /// Price for [gb], in cents: the per-GB retail rate, landed on a normal
  /// App Store price point (x.99).
  static int priceCentsFor(int gb) {
    final raw = gb * StorageEconomics.pricePerGb * 100; // cents
    // Round up to the next whole dollar, then shave a cent → $N.99.
    final dollars = (raw / 100).ceil();
    return dollars * 100 - 1;
  }

  static StoragePlan planForGb(int gb) => StoragePlan(gb, priceCentsFor(gb));

  /// The free plan plus every paid size, cheapest first.
  static List<StoragePlan> get plans => [
        const StoragePlan(freeGb, 0),
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

  int get quotaBytes => activeGb * _bytesPerGb;
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
  bool get isFull => _usedBytes >= quotaBytes;

  /// Within the last 10% — worth nudging.
  bool get nearLimit => usedFraction >= 0.9;

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
