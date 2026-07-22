import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A single earnable badge. A badge unlocks when the score reaches [threshold]
/// (when non-null) or when its [flag] has been recorded (a one-off achievement
/// like making a call or getting verified).
@immutable
class Badge {
  final String id;
  final String emoji;
  final String label;
  final String description;
  final int? threshold;
  final String? flag;

  const Badge({
    required this.id,
    required this.emoji,
    required this.label,
    required this.description,
    this.threshold,
    this.flag,
  });
}

/// The Okay Score: a running activity tally (à la Snapchat's Snapscore) plus
/// the badges it unlocks. Persisted on-device; nothing about it is stored on a
/// server — your own score is broadcast to a contact only when you message
/// them, exactly like your name.
class ScoreStore extends ChangeNotifier {
  ScoreStore._();
  static final ScoreStore instance = ScoreStore._();

  /// Points awarded for each kind of activity.
  static const int pointsPerSend = 2;
  static const int pointsPerReceive = 1;
  static const int pointsPerCall = 5;

  /// The full badge catalog, ordered from easiest to rarest.
  static const List<Badge> catalog = [
    Badge(
        id: 'starter',
        emoji: '🌱',
        label: 'Getting started',
        description: 'Send your first message',
        threshold: 2),
    Badge(
        id: 'caller',
        emoji: '📞',
        label: 'On the line',
        description: 'Place a voice or video call',
        flag: 'made_call'),
    Badge(
        id: 'chatty',
        emoji: '💬',
        label: 'Chatterbox',
        description: 'Reach 50 points',
        threshold: 50),
    Badge(
        id: 'century',
        emoji: '💯',
        label: 'Century',
        description: 'Reach 100 points',
        threshold: 100),
    Badge(
        id: 'social',
        emoji: '🎉',
        label: 'Social butterfly',
        description: 'Reach 250 points',
        threshold: 250),
    Badge(
        id: 'verified',
        emoji: '✅',
        label: 'Verified',
        description: 'Get the blue check with Okay Pro',
        flag: 'verified'),
    Badge(
        id: 'pro',
        emoji: '⭐',
        label: 'Okay Pro',
        description: 'Subscribe to Okay Pro',
        flag: 'pro'),
    Badge(
        id: 'legend',
        emoji: '🏆',
        label: 'Legend',
        description: 'Reach 500 points',
        threshold: 500),
  ];

  static Badge? badgeById(String id) {
    for (final b in catalog) {
      if (b.id == id) return b;
    }
    return null;
  }

  static const _kPoints = 'okay_score_points';
  static const _kFlags = 'okay_score_flags';
  static const _kFeatured = 'okay_score_featured';

  SharedPreferences? _prefs;

  int _points = 0;
  final Set<String> _flags = <String>{};
  String? _featured;

  int get points => _points;
  Set<String> get flags => Set.unmodifiable(_flags);

  /// The badge the user has chosen to show on their profile, if still earned.
  String? get featuredBadge =>
      (_featured != null && isEarned(_featured!)) ? _featured : null;

  /// Whether [badgeId] has been unlocked.
  bool isEarned(String badgeId) {
    final b = badgeById(badgeId);
    if (b == null) return false;
    if (b.threshold != null && _points >= b.threshold!) return true;
    if (b.flag != null && _flags.contains(b.flag)) return true;
    return false;
  }

  /// All currently-unlocked badges, in catalog order.
  List<Badge> get earnedBadges =>
      catalog.where((b) => isEarned(b.id)).toList(growable: false);

  int get earnedCount => earnedBadges.length;

  /// Loads the saved score at startup.
  Future<void> load() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    _points = prefs.getInt(_kPoints) ?? 0;
    _flags
      ..clear()
      ..addAll(prefs.getStringList(_kFlags) ?? const []);
    _featured = prefs.getString(_kFeatured);
    notifyListeners();
  }

  /// Adds [delta] points (ignoring non-positive deltas) and persists.
  void award(int delta) {
    if (delta <= 0) return;
    _points += delta;
    _persist();
    notifyListeners();
  }

  /// Records a one-off achievement [flag] (e.g. 'made_call', 'verified').
  void recordFlag(String flag) {
    if (_flags.add(flag)) {
      _persist();
      notifyListeners();
    }
  }

  /// Clears a flag (e.g. when verification is turned off).
  void clearFlag(String flag) {
    if (_flags.remove(flag)) {
      if (_featured == 'verified' && flag == 'verified') _featured = null;
      _persist();
      notifyListeners();
    }
  }

  /// Chooses which earned badge to feature on the profile (null clears it).
  void setFeatured(String? badgeId) {
    if (badgeId != null && !isEarned(badgeId)) return;
    _featured = badgeId;
    _persist();
    notifyListeners();
  }

  void _persist() {
    _prefs?.setInt(_kPoints, _points);
    _prefs?.setStringList(_kFlags, _flags.toList());
    if (_featured == null) {
      _prefs?.remove(_kFeatured);
    } else {
      _prefs?.setString(_kFeatured, _featured!);
    }
  }

  @visibleForTesting
  void resetForTest() {
    _points = 0;
    _flags.clear();
    _featured = null;
    _prefs = null;
    notifyListeners();
  }
}
