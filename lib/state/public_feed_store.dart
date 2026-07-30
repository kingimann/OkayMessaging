import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../app_state.dart';
import '../relay/relay_config.dart';
import 'account_service.dart';
import 'feed_mute_store.dart';
import 'follow_store.dart';
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

  /// The post this repeats. With a [body] it reads as a quote post, without
  /// one as a plain repost.
  final String? repostOf;

  /// Object name inside the public-media bucket, or '' for no image. A path
  /// rather than a URL, so moving the project doesn't strand every image.
  final String imagePath;
  final DateTime createdAt;
  final int likeCount;
  final int replyCount;
  final int repostCount;

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
    this.repostOf,
    this.imagePath = '',
    required this.createdAt,
    this.likeCount = 0,
    this.replyCount = 0,
    this.repostCount = 0,
    this.liked = false,
    this.mine = false,
  });

  /// Whether this carries an image.
  bool get hasImage => imagePath.isNotEmpty;

  /// Whether this repeats another post without adding anything.
  bool get isPlainRepost => repostOf != null && body.isEmpty;

  PublicPost copyWith({
    int? likeCount,
    int? replyCount,
    int? repostCount,
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
        repostOf: repostOf,
        imagePath: imagePath,
        createdAt: createdAt,
        likeCount: likeCount ?? this.likeCount,
        replyCount: replyCount ?? this.replyCount,
        repostCount: repostCount ?? this.repostCount,
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
        repostOf: r['repost_of'] as String?,
        imagePath: r['image_path'] as String? ?? '',
        createdAt: DateTime.tryParse(r['created_at'] as String? ?? '')
                ?.toLocal() ??
            DateTime.now(),
        likeCount: (r['like_count'] as num?)?.toInt() ?? 0,
        replyCount: (r['reply_count'] as num?)?.toInt() ?? 0,
        repostCount: (r['repost_count'] as num?)?.toInt() ?? 0,
      );
}

/// Why a post could not be made, in words a screen can show.
class PublicFeedError implements Exception {
  final String reason;
  PublicFeedError(this.reason);
  @override
  String toString() => reason;
}

/// The tabs on somebody's profile.
enum ProfileTab {
  posts,
  replies,
  media;

  String get label => switch (this) {
        ProfileTab.posts => 'Posts',
        ProfileTab.replies => 'Replies',
        ProfileTab.media => 'Media',
      };
}

/// How the timeline is narrowed.
enum FeedFilter {
  /// Everything, newest first.
  latest,

  /// Everything, most-liked first.
  top,

  /// Only people you follow (plus yourself), newest first.
  following;

  String get label => switch (this) {
        FeedFilter.latest => 'Latest',
        FeedFilter.top => 'Top',
        FeedFilter.following => 'Following',
      };
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
      'repost_of, image_path, created_at, like_count, reply_count, '
      'repost_count';

  /// The columns the first version of the view had.
  ///
  /// The app and the page deploy the moment they are pushed; the SQL is pasted
  /// into a dashboard by hand, whenever somebody gets to it. So there is always
  /// a window where the client asks for columns the view hasn't got, and asking
  /// for one missing column fails the whole request — the feed goes blank, with
  /// nothing said about why.
  ///
  /// A timeline without reposts or images is worth far more than no timeline,
  /// so fall back to this and keep going.
  static const String _legacyColumns =
      'id, author_username, author_name, author_verified, body, reply_to, '
      'created_at, like_count, reply_count';

  /// Set once the view has been found to predate reposts and images. Sticky for
  /// the session: retrying the wide query on every page would double the
  /// requests for a schema that isn't going to change under us.
  bool _legacyView = false;

  /// Whether the server's feed is too old for reposts and images.
  bool get legacyView => _legacyView;

  /// Whether a Postgres error code means "you asked for a column I haven't
  /// got". Named so the retry above reads as a decision rather than a magic
  /// number, and so it can be tested without a database.
  @visibleForTesting
  static bool isMissingColumn(String? code) => code == '42703';

  List<PublicPost> _posts = [];
  bool _loading = false;
  bool _loadingMore = false;
  bool _reachedEnd = false;
  String? _error;

  /// How the timeline is narrowed. Applied server-side where the database can
  /// do it, so a filter isn't a lie about a page of already-loaded posts.
  FeedFilter _filter = FeedFilter.latest;
  String _query = '';
  String _tag = '';

  FeedFilter get filter => _filter;
  String get query => _query;
  String get tag => _tag;
  bool get loadingMore => _loadingMore;

  /// Whether the last page came back short, meaning there is nothing more.
  bool get reachedEnd => _reachedEnd;

  /// The timeline: top-level posts (never replies), ordered by the active
  /// filter, with muted authors left out. Top sorts by likes, then reposts,
  /// then recency, so a tie doesn't reshuffle on every rebuild.
  ///
  /// Muting is applied here rather than in the query because it lives on the
  /// device — there is no column for it to filter on. The consequence is that a
  /// page can arrive shorter than it was fetched, which is the right trade: a
  /// mute nobody can see is worth more than a page that is exactly forty long.
  List<PublicPost> get posts {
    final list = _posts
        .where((p) =>
            p.replyTo == null && !FeedMuteStore.instance.isMuted(p.authorUsername))
        .toList();
    if (_filter == FeedFilter.top) {
      list.sort((a, b) {
        final byLikes = b.likeCount.compareTo(a.likeCount);
        if (byLikes != 0) return byLikes;
        final byReposts = b.repostCount.compareTo(a.repostCount);
        if (byReposts != 0) return byReposts;
        return b.createdAt.compareTo(a.createdAt);
      });
    }
    return List.unmodifiable(list);
  }

  bool get loading => _loading;

  /// Why the last load failed, or null.
  String? get error => _error;

  /// Whether a feed exists to talk to at all. The debug hook counts, so a test
  /// exercises the same screen path a phone does rather than the no-server one.
  bool get isConfigured =>
      RelayConfig.isEnabled ||
      debugLoadOverride != null ||
      debugProfileOverride != null;

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
  ///
  /// Empty text is fine when the post carries something else — an image or a
  /// repost — which mirrors the CHECK on the table rather than guessing at it.
  static String? validate(String text,
      {bool hasImage = false, bool isRepost = false}) {
    final t = text.trim();
    if (t.isEmpty && !hasImage && !isRepost) return 'Write something first.';
    if (t.length > maxLength) {
      return 'That\'s ${t.length - maxLength} characters too long.';
    }
    return null;
  }

  /// Hashtags in [text], lowercased and deduplicated, in order. Pure.
  static List<String> tagsIn(String text) {
    final out = <String>[];
    for (final m in RegExp(r'#([A-Za-z0-9_]{1,40})').allMatches(text)) {
      final tag = m.group(1)!.toLowerCase();
      if (!out.contains(tag)) out.add(tag);
    }
    return out;
  }

  /// The tags used most across [posts], most-used first, then alphabetically so
  /// ties don't shuffle between rebuilds. Pure.
  static List<(String, int)> trendingTags(List<PublicPost> posts,
      {int take = 8}) {
    final counts = <String, int>{};
    for (final p in posts) {
      for (final t in tagsIn(p.body)) {
        counts[t] = (counts[t] ?? 0) + 1;
      }
    }
    final entries = counts.entries.toList()
      ..sort((a, b) {
        final byCount = b.value.compareTo(a.value);
        return byCount != 0 ? byCount : a.key.compareTo(b.key);
      });
    return [for (final e in entries.take(take)) (e.key, e.value)];
  }

  /// Narrows the timeline and reloads. Server-side wherever the database can
  /// do the filtering, so a filter means the whole feed and not just the page
  /// already in memory.
  Future<void> setFilter(FeedFilter f) async {
    if (_filter == f) return;
    _filter = f;
    await load();
  }

  /// Free-text search over post bodies. Empty clears it.
  Future<void> search(String text) async {
    final q = text.trim();
    if (_query == q) return;
    _query = q;
    await load();
  }

  /// Narrows to one hashtag (without the '#'). Empty clears it.
  Future<void> setTag(String tag) async {
    final t = tag.trim().toLowerCase().replaceFirst('#', '');
    if (_tag == t) return;
    _tag = t;
    await load();
  }

  /// How many posts a page holds.
  static const int pageSize = 40;

  /// Reads the newest posts, and which of them this account has liked.
  Future<void> load({int limit = pageSize}) async {
    _loading = true;
    _error = null;
    _reachedEnd = false;
    notifyListeners();
    try {
      final fetched = await _fetch(limit: limit, before: null);
      _posts = fetched;
      _reachedEnd = fetched.length < limit;
    } catch (e) {
      _error = e is PublicFeedError ? e.reason : 'Couldn\'t load the feed.';
    }
    _loading = false;
    notifyListeners();
  }

  /// Appends the next page. No-op while one is in flight or at the end.
  Future<void> loadMore() async {
    if (_loadingMore || _reachedEnd || _posts.isEmpty) return;
    _loadingMore = true;
    notifyListeners();
    try {
      final oldest = _posts
          .map((p) => p.createdAt)
          .reduce((a, b) => a.isBefore(b) ? a : b);
      final more = await _fetch(limit: pageSize, before: oldest);
      final known = {for (final p in _posts) p.id};
      final fresh = [
        for (final p in more)
          if (!known.contains(p.id)) p
      ];
      _posts = [..._posts, ...fresh];
      // Judged on what the server returned, not on what survived de-duping:
      // a page of all-duplicates still means there may be more behind it.
      _reachedEnd = more.length < pageSize;
    } catch (_) {
      // Leave what is already shown; the button can be pressed again.
    }
    _loadingMore = false;
    notifyListeners();
  }

  /// One page from the view, with the active filter applied server-side.
  Future<List<PublicPost>> _fetch(
      {required int limit, required DateTime? before}) async {
    final override = debugLoadOverride;
    if (override != null) {
      final all = await override();
      // The hook stands in for the server, so apply the same narrowing here or
      // a test would exercise a filter that does nothing.
      return _applyFilterLocally(all, limit: limit, before: before);
    }
    final client = _client;
    if (client == null) throw PublicFeedError('No server configured.');
    var q = client
        .from('public_feed')
        .select(_legacyView ? _legacyColumns : _columns);
    if (_query.isNotEmpty) {
      q = q.ilike('body', '%${_escapeLike(_query)}%');
    }
    if (_tag.isNotEmpty) {
      q = q.ilike('body', '%#${_escapeLike(_tag)}%');
    }
    if (_filter == FeedFilter.following) {
      final mine = AppState.profile.value.username;
      final names = <String>{
        ...FollowStore.instance.following,
        if (mine.isNotEmpty) mine,
      }..removeWhere((u) => u.isEmpty);
      // Following nobody means an empty timeline, not the whole feed.
      if (names.isEmpty) return const [];
      q = q.inFilter('author_username', names.toList());
    }
    if (before != null) {
      q = q.lt('created_at', before.toUtc().toIso8601String());
    }
    final List<dynamic> rows;
    try {
      rows = await q.order('created_at', ascending: false).limit(limit);
    } on PostgrestException catch (e) {
      // 42703 is "column does not exist". The view is behind the app, so ask
      // for what it does have and try again — once, from the top, because the
      // builder above has already been spent.
      if (isMissingColumn(e.code) && !_legacyView) {
        _legacyView = true;
        return _fetch(limit: limit, before: before);
      }
      rethrow;
    }
    return _hydrate(rows);
  }

  /// Rows to posts, with this account's own likes and authorship filled in.
  /// Shared with the profile query so the two cannot disagree about what
  /// "mine" or "liked" means.
  Future<List<PublicPost>> _hydrate(List<dynamic> rows) async {
    final mineUsername = AppState.profile.value.username;
    final liked = await _myLikes();
    return [
      for (final r in rows)
        () {
          final post = PublicPost.fromRow(Map<String, dynamic>.from(r as Map));
          return post.copyWith(
            liked: liked.contains(post.id),
            // Attribution is by username, so that is what "mine" can honestly
            // mean here — the phone column is not readable.
            mine: mineUsername.isNotEmpty &&
                post.authorUsername == mineUsername,
          );
        }(),
    ];
  }

  /// Test hook: stands in for one person's posts.
  @visibleForTesting
  static Future<List<PublicPost>> Function(String username)?
      debugProfileOverride;

  /// Everything [username] has posted, newest first — replies included, since
  /// a profile shows those on their own tab.
  ///
  /// Deliberately does not touch the loaded timeline: opening a profile must
  /// not throw away the feed somebody scrolled through to get there.
  Future<List<PublicPost>> postsBy(String username,
      {int limit = pageSize, DateTime? before}) async {
    final override = debugProfileOverride;
    if (override != null) {
      final all = await override(username);
      final list = [
        for (final p in all)
          if (p.authorUsername == username &&
              (before == null || p.createdAt.isBefore(before)))
            p
      ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return list.take(limit).toList();
    }
    final client = _client;
    if (client == null) throw PublicFeedError('No server configured.');
    var q = client
        .from('public_feed')
        .select(_legacyView ? _legacyColumns : _columns)
        .eq('author_username', username);
    if (before != null) {
      q = q.lt('created_at', before.toUtc().toIso8601String());
    }
    final List<dynamic> rows;
    try {
      rows = await q.order('created_at', ascending: false).limit(limit);
    } on PostgrestException catch (e) {
      if (isMissingColumn(e.code) && !_legacyView) {
        _legacyView = true;
        return postsBy(username, limit: limit, before: before);
      }
      throw PublicFeedError(_explain(e));
    }
    return _hydrate(rows);
  }

  /// Test hook: stands in for a by-id fetch.
  @visibleForTesting
  static Future<List<PublicPost>> Function(List<String> ids)? debugByIdsOverride;

  /// Specific posts by id, newest first. For bookmarks, which are ids on a
  /// device and nothing on the server.
  ///
  /// Ids that come back missing are reported, not silently dropped: a saved post
  /// that has been deleted should leave the list rather than sit in it.
  Future<(List<PublicPost>, List<String> missing)> postsByIds(
      List<String> ids) async {
    if (ids.isEmpty) return (const <PublicPost>[], const <String>[]);
    final override = debugByIdsOverride;
    final List<PublicPost> found;
    if (override != null) {
      found = await override(ids);
    } else {
      final client = _client;
      if (client == null) throw PublicFeedError('No server configured.');
      try {
        final rows = await client
            .from('public_feed')
            .select(_legacyView ? _legacyColumns : _columns)
            .inFilter('id', ids)
            .order('created_at', ascending: false);
        found = await _hydrate(rows);
      } on PostgrestException catch (e) {
        if (isMissingColumn(e.code) && !_legacyView) {
          _legacyView = true;
          return postsByIds(ids);
        }
        throw PublicFeedError(_explain(e));
      }
    }
    final present = {for (final p in found) p.id};
    return (found, [for (final id in ids) if (!present.contains(id)) id]);
  }

  /// A profile's three tabs, from one list of that person's posts. Pure, so
  /// what each tab contains is a rule rather than a query somebody can drift.
  static List<PublicPost> profileTab(List<PublicPost> all, ProfileTab tab) =>
      switch (tab) {
        // Reposts belong on Posts: on a profile they are things this person
        // put in front of their followers, which is what the tab is for.
        ProfileTab.posts => [for (final p in all) if (p.replyTo == null) p],
        ProfileTab.replies => [for (final p in all) if (p.replyTo != null) p],
        ProfileTab.media => [for (final p in all) if (p.hasImage) p],
      };

  /// The same narrowing the query does, for the test hook. Kept beside it so
  /// the two cannot drift apart unnoticed.
  List<PublicPost> _applyFilterLocally(List<PublicPost> all,
      {required int limit, required DateTime? before}) {
    var list = all;
    if (_query.isNotEmpty) {
      final q = _query.toLowerCase();
      list = list.where((p) => p.body.toLowerCase().contains(q)).toList();
    }
    if (_tag.isNotEmpty) {
      list = list.where((p) => tagsIn(p.body).contains(_tag)).toList();
    }
    if (_filter == FeedFilter.following) {
      final mine = AppState.profile.value.username;
      final names = <String>{
        ...FollowStore.instance.following,
        if (mine.isNotEmpty) mine,
      }..removeWhere((u) => u.isEmpty);
      if (names.isEmpty) return const [];
      list = list.where((p) => names.contains(p.authorUsername)).toList();
    }
    if (before != null) {
      list = list.where((p) => p.createdAt.isBefore(before)).toList();
    }
    return list.take(limit).toList();
  }

  /// Escapes the wildcards in a LIKE pattern so a literal % or _ in a search
  /// doesn't match everything.
  static String _escapeLike(String raw) =>
      raw.replaceAll('\\', '').replaceAll('%', '').replaceAll('_', ' ');

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
  Future<void> post(String text,
      {String? replyTo, String? repostOf, Uint8List? image}) async {
    final problem = validate(text,
        hasImage: image != null, isRepost: repostOf != null);
    if (problem != null) throw PublicFeedError(problem);
    if (replyTo != null && repostOf != null) {
      // The table refuses this too; catching it here keeps the message useful.
      throw PublicFeedError('A post can be a reply or a repost, not both.');
    }
    final me = AppState.profile.value;
    final phone = local.Session.instance.user.value?.phone ?? me.phone;
    if (phone.trim().isEmpty) {
      throw PublicFeedError('Sign in to post.');
    }
    final id = newId();
    // The image goes up first: a post pointing at an object that failed to
    // upload would render a broken box for everyone, forever.
    var imagePath = '';
    if (image != null) {
      imagePath = await _uploadImage(id, image);
    }
    final post = PublicPost(
      id: id,
      authorUsername: me.username,
      authorName: me.name,
      authorVerified: me.verified,
      body: text.trim(),
      replyTo: replyTo,
      repostOf: repostOf,
      imagePath: imagePath,
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
          if (repostOf != null) 'repost_of': repostOf,
          if (imagePath.isNotEmpty) 'image_path': imagePath,
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
    if (repostOf != null) {
      _posts = [
        for (final p in _posts)
          p.id == repostOf ? p.copyWith(repostCount: p.repostCount + 1) : p
      ];
    }
    notifyListeners();
  }

  /// Bucket holding post images. Public, because the posts are: sealing an
  /// attachment on a world-readable post would mean a world-readable key.
  static const String bucket = 'public-media';

  /// The biggest image a post may carry. Matches the bucket's own limit, so
  /// somebody is told before the upload rather than after.
  static const int maxImageBytes = 4 * 1024 * 1024;

  /// Where to fetch a post's image from, or null when it has none.
  static String? imageUrlFor(PublicPost post) {
    if (!post.hasImage || !RelayConfig.isEnabled) return null;
    return '${RelayConfig.supabaseUrl}/storage/v1/object/public/'
        '$bucket/${post.imagePath}';
  }

  /// Test hook: replaces the bucket round trip.
  @visibleForTesting
  static Future<String> Function(String id, Uint8List bytes)?
      debugUploadOverride;

  /// Puts an image in the bucket and returns its object name.
  Future<String> _uploadImage(String id, Uint8List bytes) async {
    if (bytes.length > maxImageBytes) {
      throw PublicFeedError(
          'That image is over ${maxImageBytes ~/ (1024 * 1024)} MB. '
          'Pick a smaller one.');
    }
    final override = debugUploadOverride;
    if (override != null) return override(id, bytes);
    final client = _client;
    if (client == null) throw PublicFeedError('No server configured.');
    final name = '$id.jpg';
    try {
      await client.storage.from(bucket).uploadBinary(name, bytes,
          fileOptions: const FileOptions(contentType: 'image/jpeg'));
      return name;
    } catch (e) {
      final text = '$e';
      if (text.contains('Bucket not found')) {
        throw PublicFeedError('Image posting isn\'t set up on the server yet.'
            '\n\n(re-run docs/public_feed.sql)');
      }
      throw PublicFeedError('Couldn\'t upload that image.');
    }
  }

  /// The handle a reply is replying to, or null when the parent isn't loaded.
  /// Never guessed: a wrong "Replying to @somebody" is worse than no line.
  String? replyingTo(PublicPost post) {
    final parent = post.replyTo;
    if (parent == null) return null;
    final found = byId(parent);
    final username = found?.authorUsername ?? '';
    return username.isEmpty ? null : username;
  }

  /// This account's repost of [postId], or null. Matched on username, since the
  /// author phone is deliberately unreadable.
  PublicPost? myRepostOf(String postId) {
    final me = AppState.profile.value.username;
    if (me.isEmpty) return null;
    for (final p in _posts) {
      if (p.repostOf == postId && p.authorUsername == me && p.body.isEmpty) {
        return p;
      }
    }
    return null;
  }

  /// Reposts [postId], or undoes it when this account already has.
  Future<void> toggleRepost(String postId) async {
    final existing = myRepostOf(postId);
    if (existing != null) {
      await delete(existing.id);
      _apply(postId,
          (p) => p.copyWith(repostCount: (p.repostCount - 1).clamp(0, 1 << 30)));
      return;
    }
    await post('', repostOf: postId);
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
    if (text.contains('42703') ||
        (text.contains('column') && text.contains('does not exist'))) {
      return 'The server\'s feed is missing something this app expects.\n\n'
          '(re-run docs/public_feed.sql)';
    }
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
    debugUploadOverride = null;
    debugProfileOverride = null;
    debugByIdsOverride = null;
    _filter = FeedFilter.latest;
    _query = '';
    _tag = '';
    _reachedEnd = false;
    _loadingMore = false;
    _legacyView = false;
    notifyListeners();
  }
}
