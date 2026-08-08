import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How often the automatic backup runs as a periodic backstop, on top of the
/// responsive upload that follows a change.
enum BackupInterval { daily, weekly }

/// The user's control over the cloud backup: whether it runs automatically,
/// how often as a backstop, and which categories it carries. On the device
/// only — a preference, not synced (it decides what gets synced).
///
/// Chats are NOT one of these categories: message content is backed up
/// separately, on request, under a key only the user holds (see CloudSync's
/// chat backup). These toggles govern the communal blob — servers, feed,
/// follows, places, notes, score, contacts.
class BackupPrefs extends ChangeNotifier {
  BackupPrefs._();
  static final BackupPrefs instance = BackupPrefs._();

  static const _kAuto = 'backup_auto';
  static const _kInterval = 'backup_interval';
  static const _kExcluded = 'backup_excluded';

  /// The categories a user can include or leave out of the communal backup,
  /// with the label shown for each. Order is the order they appear in the UI.
  static const categories = <(String, String)>[
    ('communities', 'Servers'),
    ('feed', 'Your posts'),
    ('follows', 'Follows'),
    ('places', 'Saved places'),
    ('notes', 'Notes'),
    ('score', 'Okay Score'),
    ('contacts', 'Saved contacts'),
  ];

  SharedPreferences? _prefs;
  bool _autoBackup = true;
  BackupInterval _interval = BackupInterval.daily;
  final Set<String> _excluded = {};

  bool get autoBackup => _autoBackup;
  BackupInterval get interval => _interval;

  /// Whether [category] is carried by the backup (default: yes).
  bool includes(String category) => !_excluded.contains(category);

  Duration get intervalDuration => _interval == BackupInterval.weekly
      ? const Duration(days: 7)
      : const Duration(days: 1);

  /// Whether a periodic backup is due, given the last one at [lastSync]:
  /// automatic must be on, and either nothing has backed up yet or the
  /// interval has elapsed.
  bool dueSince(DateTime? lastSync, {DateTime? now}) {
    if (!_autoBackup) return false;
    if (lastSync == null) return true;
    return (now ?? DateTime.now()).difference(lastSync) >= intervalDuration;
  }

  Future<void> load() async {
    _prefs ??= await SharedPreferences.getInstance();
    _autoBackup = _prefs!.getBool(_kAuto) ?? true;
    _interval = (_prefs!.getString(_kInterval) == 'weekly')
        ? BackupInterval.weekly
        : BackupInterval.daily;
    _excluded
      ..clear()
      ..addAll(_prefs!.getStringList(_kExcluded) ?? const []);
    notifyListeners();
  }

  Future<void> setAutoBackup(bool on) async {
    if (_autoBackup == on) return;
    _autoBackup = on;
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setBool(_kAuto, on);
    notifyListeners();
  }

  Future<void> setInterval(BackupInterval interval) async {
    if (_interval == interval) return;
    _interval = interval;
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setString(
        _kInterval, interval == BackupInterval.weekly ? 'weekly' : 'daily');
    notifyListeners();
  }

  Future<void> setIncluded(String category, bool on) async {
    final changed = on ? _excluded.remove(category) : _excluded.add(category);
    if (!changed) return;
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setStringList(_kExcluded, _excluded.toList());
    notifyListeners();
  }

  @visibleForTesting
  void resetForTest() {
    _prefs = null;
    _autoBackup = true;
    _interval = BackupInterval.daily;
    _excluded.clear();
  }
}
