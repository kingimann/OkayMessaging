import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One outgoing live-location share: you, sharing YOUR position with one
/// contact until [until]. [lat]/[lng] are the last position that went out, so
/// your own message bubble can draw a pin without re-reading the GPS.
@immutable
class LiveShare {
  const LiveShare({
    required this.chatId,
    required this.phone,
    required this.until,
    required this.lat,
    required this.lng,
    required this.messageId,
  });

  final String chatId;
  final String phone;
  final DateTime until;
  final double lat;
  final double lng;

  /// The chat message this share's bubble is drawn from — carried so
  /// stopping the share can tell the recipient EXACTLY which of their
  /// incoming live-location messages to close (see
  /// `RelayService.sendLiveLocationStop` / `ChatStore.endIncomingLiveLocation`).
  final String messageId;

  bool expiredAt(DateTime now) => !now.isBefore(until);

  LiveShare withPosition(double lat, double lng) => LiveShare(
      chatId: chatId,
      phone: phone,
      until: until,
      lat: lat,
      lng: lng,
      messageId: messageId);

  Map<String, dynamic> toJson() => {
        'chatId': chatId,
        'phone': phone,
        'until': until.toIso8601String(),
        'lat': lat,
        'lng': lng,
        'messageId': messageId,
      };

  static LiveShare? fromJson(Map<String, dynamic> j) {
    final until = DateTime.tryParse(j['until'] as String? ?? '');
    final lat = (j['lat'] as num?)?.toDouble();
    final lng = (j['lng'] as num?)?.toDouble();
    if (until == null || lat == null || lng == null) return null;
    return LiveShare(
      chatId: j['chatId'] as String? ?? '',
      phone: j['phone'] as String? ?? '',
      until: until,
      lat: lat,
      lng: lng,
      // Older persisted shares (before this field existed) have no message
      // id to stop precisely by — empty means "can't target a stop signal",
      // handled by the caller rather than guessing one.
      messageId: j['messageId'] as String? ?? '',
    );
  }
}

/// The live shares YOU currently have running, keyed by the contact's phone
/// digits. Persisted, so a one-hour share survives closing the app — otherwise
/// "sharing until 3pm" would quietly stop the moment the phone locked. Expired
/// shares are pruned on load and by the broadcaster.
class LiveShareStore extends ChangeNotifier {
  LiveShareStore._();
  static final LiveShareStore instance = LiveShareStore._();

  static const _key = 'live_shares_v1';

  /// The durations offered when you start a share.
  static const List<Duration> options = [
    Duration(minutes: 15),
    Duration(hours: 1),
    Duration(hours: 8),
  ];

  final Map<String, LiveShare> _byDigits = {};
  SharedPreferences? _prefs;

  static String digitsOf(String phone) => phone.replaceAll(RegExp(r'\D'), '');

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    _byDigits.clear();
    try {
      final raw = _prefs!.getString(_key);
      if (raw != null && raw.isNotEmpty) {
        for (final e in (jsonDecode(raw) as Map).entries) {
          final share = LiveShare.fromJson(Map<String, dynamic>.from(e.value));
          if (share != null) _byDigits[e.key as String] = share;
        }
      }
    } catch (_) {}
    _prune(DateTime.now());
    notifyListeners();
  }

  /// Starts (or replaces) a live share with the contact at [phone]. [messageId]
  /// is the chat message this share's bubble is drawn from — carried so a
  /// later Stop can name exactly which message to close for the recipient.
  Future<void> start(String chatId, String phone, DateTime until, double lat,
      double lng, String messageId) async {
    final d = digitsOf(phone);
    if (d.isEmpty) return;
    _byDigits[d] = LiveShare(
        chatId: chatId,
        phone: phone,
        until: until,
        lat: lat,
        lng: lng,
        messageId: messageId);
    notifyListeners();
    await _persist();
  }

  /// Ends the share with the contact whose digits are [digits], returning
  /// the share that was removed (so the caller can tell the peer which
  /// message to close — see `RelayService.sendLiveLocationStop`) or null if
  /// there was none.
  Future<LiveShare?> stop(String digits) async {
    final removed = _byDigits.remove(digits);
    if (removed != null) {
      notifyListeners();
      await _persist();
    }
    return removed;
  }

  /// Records the latest position sent to [digits] (from the broadcaster).
  Future<void> updatePosition(String digits, double lat, double lng) async {
    final s = _byDigits[digits];
    if (s == null) return;
    _byDigits[digits] = s.withPosition(lat, lng);
    notifyListeners();
    await _persist();
  }

  /// The active (unexpired) share for [digits], or null.
  LiveShare? shareFor(String digits, {DateTime? now}) {
    final s = _byDigits[digits];
    if (s == null) return null;
    return s.expiredAt(now ?? DateTime.now()) ? null : s;
  }

  bool isSharingTo(String digits, {DateTime? now}) =>
      shareFor(digits, now: now) != null;

  /// How long is left on the share to [digits] (zero when none/expired).
  Duration remaining(String digits, {DateTime? now}) {
    final s = shareFor(digits, now: now);
    if (s == null) return Duration.zero;
    final left = s.until.difference(now ?? DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  /// Every unexpired share — what the broadcaster iterates.
  List<LiveShare> get active {
    final now = DateTime.now();
    return [for (final s in _byDigits.values) if (!s.expiredAt(now)) s];
  }

  bool get anyActive => active.isNotEmpty;

  /// Drops expired shares. Returns the digits whose shares just ended, so a
  /// caller can react (stamp the anchor message as ended).
  Future<List<String>> pruneExpired({DateTime? now}) async {
    final removed = _prune(now ?? DateTime.now());
    if (removed.isNotEmpty) {
      notifyListeners();
      await _persist();
    }
    return removed;
  }

  List<String> _prune(DateTime now) {
    final gone = [
      for (final e in _byDigits.entries) if (e.value.expiredAt(now)) e.key
    ];
    for (final k in gone) {
      _byDigits.remove(k);
    }
    return gone;
  }

  Future<void> _persist() async {
    await _prefs?.setString(_key,
        jsonEncode({for (final e in _byDigits.entries) e.key: e.value.toJson()}));
  }

  @visibleForTesting
  void resetForTest() {
    _byDigits.clear();
    _prefs = null;
    notifyListeners();
  }
}
