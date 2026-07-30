import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../app_state.dart';
import '../relay/relay_config.dart';
import 'account_service.dart';
import 'session.dart' as local;

/// One post on the public feed.
@immutable
class PublicPost {
  final String id;
  final String authorUsername;
  final String authorName;
  final bool authorVerified;
  final String body;

  /// The post this replies to, or null for a top-level post.
  final String? replyTo;
  final DateTime createdAt;
  final int likeCount;
  final int replyCount;

  /// Whether the signed-in account has liked this. Read from the caller's own
  /// like rows — nobody can see anyone else's.
  final bool liked;

  /// Whether this device wrote it, so it can offer to delete it.
  final bool mine;

  const PublicPost({
    required this.id,
    this.authorUsername = '',
    this.authorName = '',
    this.authorVerified = false,
    required this.body,
    this.replyTo,
    required this.createdAt,
    this.likeCount = 0,
    this.replyCount = 0,
    this.liked = false,
    this.mine = false,
  });

  PublicPost copyWith({
    int? likeCount,
    int? replyCount,
    bool? liked,
    bool? mine,
  }) =>
      PublicPost(
        id: id,
        authorUsername: authorUsername,
        authorName: authorName,
        authorVerified: authorVerified,
        body: body,
        replyTo: replyTo,
        createdAt: createdAt,
        likeCount: likeCount ?? this.likeCount,
        replyCount: replyCount ?? this.replyCount,
        liked: liked ?? this.liked,
        mine: mine ?? this.mine,
      );

  factory PublicPost.fromRow(Map<String, dynamic> r) => PublicPost(
        id: r['id'] as String? ?? '',
        authorUsername: r['author_username'] as String? ?? '',
        authorName: r['author_name'] as String? ?? '',
        authorVerified: r['author_verified'] as bool? ?? false,
        body: r['body'] as String? ?? '',
        replyTo: r['reply_to'] as String?,
        createdAt: DateTime.tryParse(r['created_at'] as String? ?? '')
                ?.toLocal() ??
            DateTime.now(),
        likeCount: (r['like_count'] as num?)?.toInt() ?? 0,
        replyCount: (r['reply_count'] as num?)?.toInt() ?? 0,
      );
}

/// Why a post could not be made, in words a screen can show.
class PublicFeedError implements Exception {
  final String reason;
  PublicFeedError(this.reason);
  @override
  String toString() => reason;
}

/// The public newsfeed — one timeline, everybody on it.
///
/// This is the only part of the app whose content the server can read, and that
/// is what "public" means rather than a compromise: a post addressed to
/// everyone cannot be encrypted to everyone. Private chats, server channels,
/// and listings are all still sealed before they leave the device and are
/// untouched by anything here.
///
/// The author's phone never travels in a readable column — Postgres revokes it
/// from every client role — so posts are attributed by username, which the
/// directory already makes public.
class PublicFeedStore extends ChangeNotifier {
  PublicFeedStore._();
  static final PublicFeedStore instance = PublicFeedStore._();

  /// The longest a post may be. Matches the CHECK on the table, so the client
  /// stops someone at the counter instead of the database rejecting it.
  static const int maxLength = 500;

  /// Columns read from the `public_feed` view. Named explicitly and never '*':
  /// the underlying table has a phone column that clients must not select, and
  /// asking for everything is how that becomes an accident.
  static const String _columns =
      'id, author_username, author_name, author_verified, body, reply_to, '
      'created_at, like_count, reply_count';

  List<PublicPost> _posts = [];
  bool _loading = false;
  String? _error;

  /// Top-level posts, newest first.
  List<PublicPost> get posts =>
      List.unmodifiable(_posts.where((p) => p.replyTo == null));

  bool get loading => _loading;

  /// Why the last load failed, or null.
  String? get error => _error;

  /// Whether a feed exists to talk to at all. The debug hook counts, so a test
  /// exercises the same screen path a phone does rather than the no-server one.
  bool get isConfigured => RelayConfig.isEnabled || debugLoadOverride != null;

  SupabaseClient? get _client {
    if (!RelayConfig.isEnabled) return null;
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null; // Supabase not initialised (tests, web preview).
    }
  }

  /// Test hook: stands in for the whole server round trip.
  @visibleForTesting
  static Future<List<PublicPost>> Function()? debugLoadOverride;

  /// Test hook: records posts instead of inserting them.
  @visibleForTesting
  static Future<void> Function(PublicPost post)? debugPostOverride;

  /// Test hook: records likes as (postId, liked).
  @visibleForTesting
  static Future<void> Function(String postId, bool liked)? debugLikeOverride;

  /// A post id nobody else will generate. Random rather than a counter so two
  /// devices posting in the same millisecond can't collide.
  static String newId() {
    final rng = Random.secure();
    final n = List<int>.generate(8, (_) => rng.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return 'pp_$n';
  }

  /// Trims and validates [text] for posting. Returns null when it's fine, or
  /// the reason it isn't. Pure.
  static String? validate(String text) {
    final t = text.trim();
    if (t.isEmpty) return 'Write something first.';
    if (t.length > maxLength) {
      return 'That\'s ${t.length - maxLength} characters too long.';
    }
    return null;
  }

  /// Reads the newest posts, and which of them this account has liked.
  Future<void> load({int limit = 100}) async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final override = debugLoadOverride;
      if (override != null) {
        _posts = await override();
      } else {
        final client = _client;
        if (client == null) throw PublicFeedError('No server configured.');
        final rows = await client
            .from('public_feed')
            .select(_columns)
            .order('created_at', ascending: false)
            .limit(limit);
        final mineUsername = AppState.profile.value.username;
        final liked = await _myLikes();
        _posts = [
          for (final r in rows)
            () {
              final post =
                  PublicPost.fromRow(Map<String, dynamic>.from(r as Map));
              return post.copyWith(
                liked: liked.contains(post.id),
                // Attribution is by username, so that is what "mine" can
                // honestly mean here.
                mine: mineUsername.isNotEmpty &&
                    post.authorUsername == mineUsername,
              );
            }(),
        ];
      }
    } catch (e) {
      _error = e is PublicFeedError ? e.reason : 'Couldn\'t load the feed.';
    }
    _loading = false;
    notifyListeners();
  }

  /// Post ids this account has liked. Own rows only — the like policy hides
  /// everyone else's, on purpose.
  Future<Set<String>> _myLikes() async {
    final client = _client;
    if (client == null) return {};
    try {
      final rows = await client.from('public_post_likes').select('post_id');
      return {
        for (final r in rows) (r as Map)['post_id'] as String? ?? '',
      }..remove('');
    } catch (_) {
      return {}; // unmigrated or offline: nothing shown as liked
    }
  }

  /// Replies to [postId], oldest first.
  List<PublicPost> repliesTo(String postId) => [
        for (final p in _posts)
          if (p.replyTo == postId) p
      ].reversed.toList();

  PublicPost? byId(String id) {
    for (final p in _posts) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// Writes a post. Throws [PublicFeedError] with something worth reading when
  /// it can't — the server's rules are the real gate, and a refusal there has
  /// to reach the person who typed.
  Future<void> post(String text, {String? replyTo}) async {
    final problem = validate(text);
    if (problem != null) throw PublicFeedError(problem);
    final me = AppState.profile.value;
    final phone = local.Session.instance.user.value?.phone ?? me.phone;
    if (phone.trim().isEmpty) {
      throw PublicFeedError('Sign in to post.');
    }
    final post = PublicPost(
      id: newId(),
      authorUsername: me.username,
      authorName: me.name,
      authorVerified: me.verified,
      body: text.trim(),
      replyTo: replyTo,
      createdAt: DateTime.now(),
      mine: true,
    );

    final override = debugPostOverride;
    if (override != null) {
      await override(post);
    } else {
      final client = _client;
      if (client == null) throw PublicFeedError('No server configured.');
      try {
        await client.from('public_posts').insert({
          'id': post.id,
          'author_phone': AccountService.e164(phone),
          'author_username': post.authorUsername,
          'author_name': post.authorName,
          'author_verified': post.authorVerified,
          'body': post.body,
          if (replyTo != null) 'reply_to': replyTo,
        });
      } catch (e) {
        throw PublicFeedError(_explain(e));
      }
    }
    // Shown immediately rather than after a round trip, and the parent's reply
    // count moves with it so the thread doesn't look empty.
    _posts = [post, ..._posts];
    if (replyTo != null) {
      _posts = [
        for (final p in _posts)
          p.id == replyTo ? p.copyWith(replyCount: p.replyCount + 1) : p
      ];
    }
    notifyListeners();
  }

  /// Likes or unlikes a post. Optimistic: the count moves at once and is put
  /// back if the server refuses.
  Future<void> toggleLike(String postId) async {
    final post = byId(postId);
    if (post == null) return;
    final wantLiked = !post.liked;
    _apply(postId, (p) => p.copyWith(
        liked: wantLiked,
        likeCount: (p.likeCount + (wantLiked ? 1 : -1)).clamp(0, 1 << 30)));

    final override = debugLikeOverride;
    try {
      if (override != null) {
        await override(postId, wantLiked);
        return;
      }
      final client = _client;
      final phone = local.Session.instance.user.value?.phone ?? '';
      if (client == null || phone.isEmpty) {
        throw PublicFeedError('Sign in to like posts.');
      }
      if (wantLiked) {
        await client.from('public_post_likes').insert({
          'post_id': postId,
          'liker_phone': AccountService.e164(phone),
        });
      } else {
        await client.from('public_post_likes').delete().eq('post_id', postId);
      }
    } catch (_) {
      // Put it back: a like that silently didn't happen is worse than one that
      // visibly bounced.
      _apply(postId, (p) => p.copyWith(
          liked: !wantLiked,
          likeCount: (p.likeCount + (wantLiked ? -1 : 1)).clamp(0, 1 << 30)));
    }
  }

  /// Deletes one of your own posts. The server only permits your own, so a
  /// refusal here means it wasn't yours.
  Future<void> delete(String postId) async {
    final client = _client;
    if (client != null) {
      try {
        await client.from('public_posts').delete().eq('id', postId);
      } catch (e) {
        throw PublicFeedError(_explain(e));
      }
    }
    // Replies go with the parent, matching the cascade on the table.
    _posts = [
      for (final p in _posts)
        if (p.id != postId && p.replyTo != postId) p
    ];
    notifyListeners();
  }

  void _apply(String id, PublicPost Function(PublicPost) f) {
    _posts = [
      for (final p in _posts) p.id == id ? f(p) : p
    ];
    notifyListeners();
  }

  /// Turns a Postgres refusal into something worth reading. The two that
  /// actually happen are the feed not being migrated yet and a sanction.
  String _explain(Object e) {
    final text = '$e';
    if (text.contains('public_posts') && text.contains('does not exist')) {
      return 'The public feed isn\'t set up on the server yet.\n\n'
          '(run docs/public_feed.sql)';
    }
    if (text.contains('row-level security') || text.contains('42501')) {
      return 'You can\'t post right now. If your account is timed out or '
          'suspended, posting comes back when that ends.';
    }
    if (text.contains('public_posts_body_check') ||
        text.contains('violates check constraint')) {
      return 'That post is too long.';
    }
    return 'Couldn\'t post. Check your connection and try again.';
  }

  @visibleForTesting
  void resetForTest() {
    _posts = [];
    _loading = false;
    _error = null;
    debugLoadOverride = null;
    debugPostOverride = null;
    debugLikeOverride = null;
    notifyListeners();
  }
}
