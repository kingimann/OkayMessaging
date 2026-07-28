import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The storage plans on offer. Deliberately no "unlimited" — every tier has a
/// hard ceiling so a single heavy user can't run costs away.
enum StorageTier { free, personal }

/// A plan's fixed facts: display name, monthly price, and the storage ceiling.
class StoragePlan {
  final StorageTier tier;
  final String name;
  final int priceCents; // per month; 0 for Free
  final int quotaBytes;
  const StoragePlan(this.tier, this.name, this.priceCents, this.quotaBytes);

  bool get isFree => priceCents == 0;
  String get priceLabel {
    if (isFree) return 'Free';
    // Whole dollars read cleaner without ".00"; otherwise show the cents.
    final dollars = priceCents / 100;
    final text = priceCents % 100 == 0
        ? dollars.toStringAsFixed(0)
        : dollars.toStringAsFixed(2);
    return '\$$text/mo';
  }
}

/// Paid chat-backup storage.
///
/// **This only ever holds chats.** Servers, feed posts, follows and the like
/// are communal — they sync to everyone in a server for free and never count
/// against anyone's quota. A user's personal storage is exactly their own
/// message history, encrypted, and only if they choose to back it up here (the
/// alternative being a local backup to iCloud / app storage).
///
/// Plans are tiered. The Free tier gives a small allowance; paid tiers are a
/// monthly subscription that raises the ceiling. A single expiry timestamp and
/// the chosen tier are persisted on-device; usage is the size of the encrypted
/// chat backup last uploaded.
class StorageStore extends ChangeNotifier {
  StorageStore._();
  static final StorageStore instance = StorageStore._();

  static const _kTier = 'cloud_storage_tier';
  static const _kActiveUntil = 'cloud_storage_active_until';
  static const _kUsedBytes = 'cloud_storage_used_bytes';

  static const int _gb = 1024 * 1024 * 1024;

  /// The catalogue, cheapest first.
  static const List<StoragePlan> plans = [
    StoragePlan(StorageTier.free, 'Free', 0, 2 * _gb),
    StoragePlan(StorageTier.personal, 'Personal', 999, 15 * _gb),
  ];

  static StoragePlan planFor(StorageTier tier) =>
      plans.firstWhere((p) => p.tier == tier);

  /// A single paid month.
  static const Duration period = Duration(days: 30);

  StorageTier _tier = StorageTier.free;
  DateTime? _activeUntil;
  int _usedBytes = 0;

  /// The tier the user is currently entitled to. A lapsed paid subscription
  /// drops back to Free.
  StorageTier get tier {
    if (_tier == StorageTier.free) return StorageTier.free;
    final until = _activeUntil;
    if (until == null || !until.isAfter(DateTime.now())) return StorageTier.free;
    return _tier;
  }

  StoragePlan get plan => planFor(tier);

  /// The tier the user has *selected/paid for*, even if currently lapsed —
  /// used to show "renew" vs "subscribe".
  StorageTier get selectedTier => _tier;

  /// True while on a paid tier that hasn't lapsed.
  bool get isPaid => tier != StorageTier.free;

  DateTime? get activeUntil => _activeUntil;

  int get daysLeft {
    final until = _activeUntil;
    if (until == null || !isPaid) return 0;
    final left = until.difference(DateTime.now());
    return left.isNegative ? 0 : left.inDays;
  }

  int get quotaBytes => plan.quotaBytes;
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

  /// At or over the plan ceiling — no more can be backed up until they free
  /// space or upgrade.
  bool get isFull => _usedBytes >= quotaBytes;

  /// Within the last 10% of the plan — worth nudging an upgrade.
  bool get nearLimit => usedFraction >= 0.9;

  /// The smallest paid plan that would hold [bytes], or null if none does
  /// (there is no unlimited tier). Powers the "upgrade to X" suggestion.
  StoragePlan? smallestPlanFor(int bytes) {
    for (final p in plans) {
      if (bytes <= p.quotaBytes) return p;
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
      final tierName = prefs.getString(_kTier);
      if (tierName != null) {
        _tier = StorageTier.values.firstWhere((t) => t.name == tierName,
            orElse: () => StorageTier.free);
      }
      final ms = prefs.getInt(_kActiveUntil);
      if (ms != null) {
        _activeUntil = DateTime.fromMillisecondsSinceEpoch(ms);
      }
      _usedBytes = prefs.getInt(_kUsedBytes) ?? 0;
      notifyListeners();
    } catch (_) {}
  }

  /// Subscribes to (or renews) [tier], adding one month. Paid months stack on
  /// any time remaining. The Free tier is just a downgrade with no expiry.
  Future<void> subscribe(StorageTier tier) async {
    _tier = tier;
    if (tier == StorageTier.free) {
      _activeUntil = null;
    } else {
      final now = DateTime.now();
      final base = (_activeUntil != null && _activeUntil!.isAfter(now))
          ? _activeUntil!
          : now;
      _activeUntil = base.add(period);
    }
    await _persist();
    notifyListeners();
  }

  /// Cancels a paid plan immediately, dropping to Free.
  Future<void> cancel() async {
    _tier = StorageTier.free;
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
      await prefs.setString(_kTier, _tier.name);
      final until = _activeUntil;
      if (until == null) {
        await prefs.remove(_kActiveUntil);
      } else {
        await prefs.setInt(_kActiveUntil, until.millisecondsSinceEpoch);
      }
    } catch (_) {}
  }

  @visibleForTesting
  void debugSubscribe(StorageTier tier, {Duration length = period}) {
    _tier = tier;
    _activeUntil =
        tier == StorageTier.free ? null : DateTime.now().add(length);
    notifyListeners();
  }

  @visibleForTesting
  void resetForTest() {
    _tier = StorageTier.free;
    _activeUntil = null;
    _usedBytes = 0;
  }
}
