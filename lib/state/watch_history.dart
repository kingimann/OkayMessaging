import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/link_preview.dart';

/// One thing watched, enough of it to play again.
class WatchedItem {
  const WatchedItem({
    required this.url,
    required this.kind,
    required this.videoId,
    required this.host,
    this.title = '',
  });

  final String url;
  final LinkKind kind;
  final String videoId;
  final String host;

  /// What the card says, when anything is known. Nothing fetches a title —
  /// see [WatchHistory] — so this is only ever what a link already carried.
  final String title;

  String get label => title.isNotEmpty ? title : url;

  LinkPreview get preview => LinkPreview(
        url: url, kind: kind, host: host, videoId: videoId, title: title);

  Map<String, dynamic> toJson() => {
        'url': url,
        'kind': kind.name,
        'videoId': videoId,
        'host': host,
        if (title.isNotEmpty) 'title': title,
      };

  static WatchedItem? fromJson(Map<String, dynamic> j) {
    final url = j['url'] as String? ?? '';
    final videoId = j['videoId'] as String? ?? '';
    if (url.isEmpty || videoId.isEmpty) return null;
    final name = j['kind'] as String? ?? '';
    // An unknown kind is a newer build's entry, not a crash.
    final kind = LinkKind.values.where((k) => k.name == name).firstOrNull;
    if (kind == null) return null;
    return WatchedItem(
      url: url,
      kind: kind,
      videoId: videoId,
      host: j['host'] as String? ?? '',
      title: j['title'] as String? ?? '',
    );
  }
}

/// What you have watched, so you do not paste the same link twice.
///
/// **On the device and nowhere else, and account-scoped.** A list of what
/// somebody watches is a fair description of them — the same reasoning that
/// keeps quick replies and saved weather cities off any server and out of the
/// backup. Nothing here is uploaded, and it is cleared on an account switch
/// (wired into `account_wipe.dart`) because the next account must not inherit
/// the last one's viewing.
///
/// **Nothing is fetched to build it.** No title lookup, no thumbnail
/// download: an entry knows only what the link itself carried, so opening
/// this screen tells YouTube and Twitch nothing at all. A row with no title
/// shows its URL rather than reaching out for a better one — the same rule
/// link previews follow by being built on the sender's device.
class WatchHistory extends ChangeNotifier {
  WatchHistory._();
  static final WatchHistory instance = WatchHistory._();

  static const String _key = 'watch_recents';

  /// Enough to be useful, short enough to stay a list rather than a feed —
  /// and a hard cap matters here, because this is a record of somebody's
  /// viewing and an unbounded one is a bigger thing to hold than a useful one.
  static const int maxItems = 20;

  final List<WatchedItem> _items = [];
  SharedPreferences? _prefs;

  List<WatchedItem> get items => List.unmodifiable(_items);

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    _items.clear();
    final raw = _prefs!.getString(_key) ?? '';
    if (raw.isNotEmpty) {
      try {
        for (final e in jsonDecode(raw) as List) {
          final item = WatchedItem.fromJson(Map<String, dynamic>.from(e));
          if (item != null) _items.add(item);
        }
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<void> _save() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    await prefs.setString(
        _key, jsonEncode([for (final i in _items) i.toJson()]));
  }

  /// Newest first, and only once: re-watching moves an entry to the top
  /// rather than adding a second copy of it.
  Future<void> remember(WatchedItem item) async {
    _items.removeWhere((i) => i.url == item.url);
    _items.insert(0, item);
    if (_items.length > maxItems) _items.removeRange(maxItems, _items.length);
    notifyListeners();
    await _save();
  }

  Future<void> forget(String url) async {
    final before = _items.length;
    _items.removeWhere((i) => i.url == url);
    if (_items.length == before) return;
    notifyListeners();
    await _save();
  }

  Future<void> clear() async {
    if (_items.isEmpty) return;
    _items.clear();
    notifyListeners();
    await _save();
  }

  @visibleForTesting
  void resetForTest() {
    _items.clear();
    _prefs = null;
  }
}
