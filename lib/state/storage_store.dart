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

  /// One month of storage, in this app's billing currency.
  static const int priceCents = 199;
  static const String currency = 'cad';
  static const String planName = 'Cloud storage';

  /// A single purchase buys this much time.
  static const Duration period = Duration(days: 30);

  DateTime? _activeUntil;

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

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ms = prefs.getInt(_kActiveUntil);
      if (ms != null) {
        _activeUntil = DateTime.fromMillisecondsSinceEpoch(ms);
      }
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
  }
}
