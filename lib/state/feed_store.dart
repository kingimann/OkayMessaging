import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_state.dart';
import '../relay/relay_config.dart';
import '../relay/relay_service.dart';

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

  /// The post this one replies to, or null for a top-level post.
  final String? parentId;

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
    this.parentId,
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
        parentId: parentId,
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
        if (parentId != null) 'parentId': parentId,
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
        parentId: j['parentId'] as String?,
      );
}

/// The X-style feed for every server, newest first. Local-only, persisted to
/// this device; demo posts are seeded per server so the feed feels alive.
class FeedStore extends ChangeNotifier {
  FeedStore._();
  static final FeedStore instance = FeedStore._();
  static const _kKey = 'server_feed_v1';

  final List<FeedPost> _posts = [];
  int _nextId = 1;

  // Moderation: locally hidden posts and muted authors.
  final Set<String> _hiddenIds = {};
  final Set<String> _mutedUsernames = {};

  Set<String> get mutedUsernames => Set.unmodifiable(_mutedUsernames);

  bool isMuted(String username) =>
      _mutedUsernames.contains(username.toLowerCase());

  /// Hides a post from this device (report uses the same mechanism).
  void hidePost(String postId) {
    _hiddenIds.add(postId);
    _save();
    notifyListeners();
  }

  /// Mutes/unmutes every post from [username]; returns true when now muted.
  bool toggleMute(String username) {
    final u = username.toLowerCase();
    final nowMuted = !_mutedUsernames.remove(u);
    if (nowMuted) _mutedUsernames.add(u);
    _save();
    notifyListeners();
    return nowMuted;
  }

  /// Top-level posts for [communityId], newest first — replies live under
  /// their parent (see [repliesTo]). With [onlyUsernames], keeps posts from
  /// those authors and your own. No seeded/demo content: every post here
  /// was written by a real person on this device or community.
  List<FeedPost> postsFor(String communityId, {Set<String>? onlyUsernames}) {
    var posts = _posts.where((p) =>
        p.communityId == communityId &&
        p.parentId == null &&
        !_hiddenIds.contains(p.id) &&
        !_mutedUsernames.contains(p.authorUsername.toLowerCase()));
    if (onlyUsernames != null) {
      posts = posts.where((p) =>
          p.authorUsername == 'you' ||
          p.authorUsername == AppState.profile.value.username ||
          onlyUsernames.contains(p.authorUsername.toLowerCase()));
    }
    final list = posts.toList()..sort((a, b) => b.time.compareTo(a.time));
    return list;
  }

  /// The most recent top-level posts across every server, newest first —
  /// what the notifications tab shows as server activity.
  List<FeedPost> recentPosts({int limit = 5}) {
    final list = _posts
        .where((p) =>
            p.parentId == null &&
            !_hiddenIds.contains(p.id) &&
            !_mutedUsernames.contains(p.authorUsername.toLowerCase()))
        .toList()
      ..sort((a, b) => b.time.compareTo(a.time));
    return list.take(limit).toList();
  }

  /// The replies under a post, oldest first (thread order).
  List<FeedPost> repliesTo(String postId) {
    final list = _posts.where((p) => p.parentId == postId).toList()
      ..sort((a, b) => a.time.compareTo(b.time));
    return list;
  }

  FeedPost? postById(String id) {
    final i = _posts.indexWhere((p) => p.id == id);
    return i < 0 ? null : _posts[i];
  }

  /// Posts [text] as the signed-in user. Returns the new post.
  FeedPost add(String communityId, String text, {String? parentId}) {
    final me = AppState.profile.value;
    final post = FeedPost(
      id: 'post_${DateTime.now().microsecondsSinceEpoch}_${_nextId++}',
      communityId: communityId,
      authorName: me.name,
      authorUsername: me.username.isEmpty ? 'you' : me.username,
      time: DateTime.now(),
      text: text.trim(),
      parentId: parentId,
    );
    _posts.add(post);
    _save();
    notifyListeners();
    // Real-time: everyone in the server sees the post, like messages.
    if (RelayConfig.isEnabled) RelayService.instance.sendFeedPost(post);
    return post;
  }

  /// Merges a post that arrived over the relay from another device.
  /// Dedupes by id; incoming replies bump their parent's count.
  void addRemote(FeedPost post) {
    if (_posts.any((p) => p.id == post.id)) return;
    _posts.add(post);
    final parentId = post.parentId;
    if (parentId != null) {
      final i = _posts.indexWhere((p) => p.id == parentId);
      if (i >= 0) {
        _posts[i] = _posts[i].copyWith(replies: _posts[i].replies + 1);
      }
    }
    _save();
    notifyListeners();
  }

  /// A threaded reply: lives under its parent and bumps its reply count.
  void reply(String postId, String text) {
    final i = _posts.indexWhere((p) => p.id == postId);
    if (i < 0) return;
    final original = _posts[i];
    add(original.communityId, text, parentId: postId);
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
    // Removes the post and its whole reply thread.
    _posts.removeWhere((p) => p.id == postId || p.parentId == postId);
    _save();
    notifyListeners();
  }

  /// Every post as JSON, for the encrypted cloud backup.
  List<Map<String, dynamic>> exportPosts() =>
      [for (final p in _posts) p.toJson()];

  /// Replaces the feed with posts from a decrypted cloud backup.
  void hydratePosts(List<dynamic> raw) {
    _posts
      ..clear()
      ..addAll(raw
          .whereType<Map>()
          .map((m) => FeedPost.fromJson(Map<String, dynamic>.from(m))));
    _save();
    notifyListeners();
  }

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kKey);
      if (raw == null) return;
      final decoded = jsonDecode(raw);
      // Older builds stored a bare list of posts; now it's a map that also
      // carries moderation state.
      final List<dynamic> rawPosts;
      if (decoded is Map) {
        rawPosts = decoded['posts'] as List? ?? const [];
        _hiddenIds
          ..clear()
          ..addAll(
              (decoded['hidden'] as List? ?? const []).whereType<String>());
        _mutedUsernames
          ..clear()
          ..addAll(
              (decoded['muted'] as List? ?? const []).whereType<String>());
      } else if (decoded is List) {
        rawPosts = decoded;
      } else {
        return;
      }
      _posts
        ..clear()
        ..addAll(rawPosts.whereType<Map<String, dynamic>>().map(
            FeedPost.fromJson));
      // Drop any demo posts persisted by earlier builds — real posts only.
      _posts.removeWhere((p) => p.id.startsWith('seed_'));
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _kKey,
          jsonEncode({
            'posts': [for (final p in _posts) p.toJson()],
            'hidden': _hiddenIds.toList(),
            'muted': _mutedUsernames.toList(),
          }));
    } catch (_) {}
  }

  @visibleForTesting
  void resetForTest() {
    _posts.clear();
    _hiddenIds.clear();
    _mutedUsernames.clear();
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
