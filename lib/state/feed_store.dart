import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_state.dart';

/// One post in a server's X-style feed.
class FeedPost {
  final String id;
  final String communityId;
  final String authorName;

  /// Username without '@' ('you' for the local user).
  final String authorUsername;
  final DateTime time;
  final String text;
  final int likes;
  final int reposts;
  final int replies;
  final bool liked;
  final bool reposted;

  const FeedPost({
    required this.id,
    required this.communityId,
    required this.authorName,
    required this.authorUsername,
    required this.time,
    required this.text,
    this.likes = 0,
    this.reposts = 0,
    this.replies = 0,
    this.liked = false,
    this.reposted = false,
  });

  FeedPost copyWith({
    int? likes,
    int? reposts,
    int? replies,
    bool? liked,
    bool? reposted,
  }) =>
      FeedPost(
        id: id,
        communityId: communityId,
        authorName: authorName,
        authorUsername: authorUsername,
        time: time,
        text: text,
        likes: likes ?? this.likes,
        reposts: reposts ?? this.reposts,
        replies: replies ?? this.replies,
        liked: liked ?? this.liked,
        reposted: reposted ?? this.reposted,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'communityId': communityId,
        'authorName': authorName,
        'authorUsername': authorUsername,
        'time': time.toIso8601String(),
        'text': text,
        'likes': likes,
        'reposts': reposts,
        'replies': replies,
        'liked': liked,
        'reposted': reposted,
      };

  factory FeedPost.fromJson(Map<String, dynamic> j) => FeedPost(
        id: j['id'] as String,
        communityId: j['communityId'] as String? ?? '',
        authorName: j['authorName'] as String? ?? '',
        authorUsername: j['authorUsername'] as String? ?? '',
        time: DateTime.tryParse(j['time'] as String? ?? '') ?? DateTime.now(),
        text: j['text'] as String? ?? '',
        likes: j['likes'] as int? ?? 0,
        reposts: j['reposts'] as int? ?? 0,
        replies: j['replies'] as int? ?? 0,
        liked: j['liked'] as bool? ?? false,
        reposted: j['reposted'] as bool? ?? false,
      );
}

/// The X-style feed for every server, newest first. Local-only, persisted to
/// this device; demo posts are seeded per server so the feed feels alive.
class FeedStore extends ChangeNotifier {
  FeedStore._();
  static final FeedStore instance = FeedStore._();
  static const _kKey = 'server_feed_v1';

  final List<FeedPost> _posts = [];
  final Set<String> _seeded = {};
  int _nextId = 1;

  /// Posts for [communityId], newest first. With [onlyUsernames], keeps
  /// posts from those authors and your own.
  List<FeedPost> postsFor(String communityId, {Set<String>? onlyUsernames}) {
    var posts = _posts.where((p) => p.communityId == communityId);
    if (onlyUsernames != null) {
      posts = posts.where((p) =>
          p.authorUsername == 'you' ||
          onlyUsernames.contains(p.authorUsername.toLowerCase()));
    }
    final list = posts.toList()..sort((a, b) => b.time.compareTo(a.time));
    return list;
  }

  /// Seeds a few demo posts the first time a server's feed is opened.
  void seedIfEmpty(String communityId) {
    if (_seeded.contains(communityId) ||
        _posts.any((p) => p.communityId == communityId)) {
      return;
    }
    _seeded.add(communityId);
    final now = DateTime.now();
    const demo = [
      ('Alice Bennett', 'aliceb', 'Shipped a little side project tonight — '
          'nothing fancy, but it works and that feels great.', 12, 3, 2, 190),
      ('Grace Hopper', 'gracehop', 'Hot take: reading old code teaches you '
          'more than writing new code.', 41, 9, 6, 130),
      ('Bob Carter', 'bobc',
          'Anyone else here basically living in this server now?', 7, 1, 4,
          75),
      ('Erin Foster', 'erinf', 'Morning run done, coffee in hand, feed '
          'checked. Perfect start.', 15, 2, 1, 30),
    ];
    for (final (name, username, text, likes, reposts, replies, minsAgo)
        in demo) {
      _posts.add(FeedPost(
        id: 'seed_${communityId}_${_nextId++}',
        communityId: communityId,
        authorName: name,
        authorUsername: username,
        time: now.subtract(Duration(minutes: minsAgo)),
        text: text,
        likes: likes,
        reposts: reposts,
        replies: replies,
      ));
    }
    _save();
    notifyListeners();
  }

  /// Posts [text] as the signed-in user. Returns the new post.
  FeedPost add(String communityId, String text) {
    final me = AppState.profile.value;
    final post = FeedPost(
      id: 'post_${DateTime.now().microsecondsSinceEpoch}_${_nextId++}',
      communityId: communityId,
      authorName: me.name,
      authorUsername: me.username.isEmpty ? 'you' : me.username,
      time: DateTime.now(),
      text: text.trim(),
    );
    _posts.add(post);
    _save();
    notifyListeners();
    return post;
  }

  /// A reply: posts as a new entry and bumps the original's reply count.
  void reply(String postId, String text) {
    final i = _posts.indexWhere((p) => p.id == postId);
    if (i < 0) return;
    final original = _posts[i];
    add(original.communityId,
        '@${original.authorUsername} ${text.trim()}');
    _posts[i] = original.copyWith(replies: original.replies + 1);
    _save();
    notifyListeners();
  }

  void toggleLike(String postId) {
    final i = _posts.indexWhere((p) => p.id == postId);
    if (i < 0) return;
    final p = _posts[i];
    _posts[i] = p.copyWith(
        liked: !p.liked, likes: p.liked ? p.likes - 1 : p.likes + 1);
    _save();
    notifyListeners();
  }

  void toggleRepost(String postId) {
    final i = _posts.indexWhere((p) => p.id == postId);
    if (i < 0) return;
    final p = _posts[i];
    _posts[i] = p.copyWith(
        reposted: !p.reposted,
        reposts: p.reposted ? p.reposts - 1 : p.reposts + 1);
    _save();
    notifyListeners();
  }

  void deletePost(String postId) {
    _posts.removeWhere((p) => p.id == postId);
    _save();
    notifyListeners();
  }

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kKey);
      if (raw == null) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      _posts
        ..clear()
        ..addAll(decoded.whereType<Map<String, dynamic>>().map(
            FeedPost.fromJson));
      // Anything already stored counts as seeded.
      _seeded.addAll(_posts.map((p) => p.communityId));
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _kKey, jsonEncode([for (final p in _posts) p.toJson()]));
    } catch (_) {}
  }

  @visibleForTesting
  void resetForTest() {
    _posts.clear();
    _seeded.clear();
    _nextId = 1;
    notifyListeners();
  }
}

/// "2m", "3h", "5d" — X-style compact age for a post.
String feedAge(DateTime time, {DateTime? now}) {
  final d = (now ?? DateTime.now()).difference(time);
  if (d.inMinutes < 1) return 'now';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) return '${d.inHours}h';
  return '${d.inDays}d';
}
