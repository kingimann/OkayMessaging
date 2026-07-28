import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Paid cloud storage entitlement.
///
/// Cloud backup used to be free and on for everyone. It's now a monthly
/// subscription: while it's active, everything except chats backs up to the
/// server automatically (see [CloudSync]). Chats never leave the device, paid
/// or not.
///
/// The entitlement is a single expiry timestamp, persisted on-device. A
/// purchase (one month) extends it by 30 days from whichever is later —
/// now, or the current expiry — so paying early stacks rather than wastes
/// days. When it lapses, automatic backup simply stops; whatever was last
/// uploaded stays on the server for restore.
class StorageStore extends ChangeNotifier {
  StorageStore._();
  static final StorageStore instance = StorageStore._();

  static const _kActiveUntil = 'cloud_storage_active_until';
  static const _kUsedBytes = 'cloud_storage_used_bytes';

  /// One month of storage, in this app's billing currency.
  static const int priceCents = 199;
  static const String currency = 'cad';
  static const String planName = 'Cloud storage';

  /// A single purchase buys this much time.
  static const Duration period = Duration(days: 30);

  /// How much a subscription includes. The backup excludes chats and media
  /// bytes, so 5 GB is far more than a text-and-metadata backup ever needs —
  /// the meter is there to be honest, not to nickel-and-dime.
  static const int quotaBytes = 5 * 1024 * 1024 * 1024;

  DateTime? _activeUntil;
  int _usedBytes = 0;

  /// When the current subscription runs out, or null if never subscribed.
  DateTime? get activeUntil => _activeUntil;

  /// True while storage is paid up. Everything gates on this.
  bool get active {
    final until = _activeUntil;
    return until != null && until.isAfter(DateTime.now());
  }

  /// Whole days remaining (0 when lapsed). Handy for the settings copy.
  int get daysLeft {
    final until = _activeUntil;
    if (until == null) return 0;
    final left = until.difference(DateTime.now());
    return left.isNegative ? 0 : left.inDays;
  }

  /// Formatted monthly price, e.g. "$1.99".
  String get priceLabel => '\$${(priceCents / 100).toStringAsFixed(2)}';

  /// Bytes the latest backup occupies on the server (its ciphertext size).
  int get usedBytes => _usedBytes;

  /// Bytes still available under the plan.
  int get availableBytes {
    final left = quotaBytes - _usedBytes;
    return left < 0 ? 0 : left;
  }

  /// Fraction of the quota in use, clamped to [0, 1] for a progress bar.
  double get usedFraction {
    if (quotaBytes <= 0) return 0;
    final f = _usedBytes / quotaBytes;
    return f < 0 ? 0 : (f > 1 ? 1 : f);
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
    // Whole numbers read cleaner without a trailing ".0".
    final rounded = value >= 100 || value == value.roundToDouble()
        ? value.round().toString()
        : value.toStringAsFixed(1);
    return '$rounded ${units[unit]}';
  }

  /// Records how big the most recent backup is. Called after every upload.
  Future<void> setUsedBytes(int bytes) async {
    if (bytes == _usedBytes) return;
    _usedBytes = bytes < 0 ? 0 : bytes;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kUsedBytes, _usedBytes);
    } catch (_) {}
    notifyListeners();
  }

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ms = prefs.getInt(_kActiveUntil);
      if (ms != null) {
        _activeUntil = DateTime.fromMillisecondsSinceEpoch(ms);
      }
      _usedBytes = prefs.getInt(_kUsedBytes) ?? 0;
      notifyListeners();
    } catch (_) {}
  }

  /// Adds one billing period. Stacks on any time already remaining so a renewal
  /// paid before expiry doesn't lose the leftover days.
  Future<void> addPeriod() async {
    final now = DateTime.now();
    final base = (_activeUntil != null && _activeUntil!.isAfter(now))
        ? _activeUntil!
        : now;
    _activeUntil = base.add(period);
    await _persist();
    notifyListeners();
  }

  /// Ends the subscription immediately (e.g. the user cancels). Data already
  /// uploaded stays; nothing new goes up until they subscribe again.
  Future<void> cancel() async {
    _activeUntil = null;
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final until = _activeUntil;
      if (until == null) {
        await prefs.remove(_kActiveUntil);
      } else {
        await prefs.setInt(_kActiveUntil, until.millisecondsSinceEpoch);
      }
    } catch (_) {}
  }

  @visibleForTesting
  void debugActivate([Duration length = period]) {
    _activeUntil = DateTime.now().add(length);
    notifyListeners();
  }

  @visibleForTesting
  void resetForTest() {
    _activeUntil = null;
    _usedBytes = 0;
  }
}
