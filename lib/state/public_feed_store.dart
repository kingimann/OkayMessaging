import 'dart:math';

import 'package:flutter/material.dart';
import 'dart:typed_data';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../app_state.dart';
import '../relay/relay_config.dart';
import 'account_service.dart';
import 'feed_mute_store.dart';
import 'feed_prefs.dart';
import 'market_media.dart';
import 'follow_store.dart';
import '../payments/payment_service.dart';
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

  /// An animated GIF, by address, or '' for none.
  ///
  /// A URL and not bytes: the GIF already lives on the provider's CDN, and
  /// copying it into our bucket would mean paying to store and serve a file
  /// somebody else serves for free.
  final String gifUrl;

  /// Object name of a video in the same bucket, or '' for none. Unsealed,
  /// unlike a server feed's video, because a public post is world-readable
  /// by definition — there is nobody to keep it from.
  final String videoPath;
  final DateTime createdAt;
  final int likeCount;
  final int replyCount;
  final int repostCount;

  /// Whether the signed-in account has liked this. Read from the caller's own
  /// like rows — nobody can see anyone else's.
  final bool liked;

  /// Whether this device wrote it, so it can offer to delete it.
  final bool mine;

  /// The answers, when this is a poll. Empty for an ordinary post.
  final List<String> pollOptions;

  /// When voting stops. Null unless this is a poll.
  final DateTime? pollClosesAt;

  /// How many votes each answer has, in the answers' own order. Comes from a
  /// counter that runs as the table's owner — the vote rows themselves are
  /// readable only by whoever cast them.
  final List<int> pollVotes;

  /// Which answer this account picked, or null for not voted. Read from your
  /// own vote row; nobody can see anyone else's.
  final int? myVote;

  /// Sparks — real-money tips pinned to this post. Counts only: who sparked
  /// is readable by nobody, and the money itself moved over Stripe.
  final int sparkCount;
  final int sparkCents;

  /// How many times this post was opened. A counter and nothing else — no
  /// viewer identity exists anywhere, on the server or here. Approximate
  /// by nature and worth exactly what an X view count is worth.
  final int viewCount;

  const PublicPost({
    required this.id,
    this.authorUsername = '',
    this.authorName = '',
    this.authorVerified = false,
    required this.body,
    this.replyTo,
    this.repostOf,
    this.imagePath = '',
    this.gifUrl = '',
    this.videoPath = '',
    required this.createdAt,
    this.likeCount = 0,
    this.replyCount = 0,
    this.repostCount = 0,
    this.liked = false,
    this.mine = false,
    this.pollOptions = const [],
    this.pollClosesAt,
    this.pollVotes = const [],
    this.myVote,
    this.sparkCount = 0,
    this.sparkCents = 0,
    this.viewCount = 0,
  });

  /// Whether this carries an image.
  bool get hasImage => imagePath.isNotEmpty;

  bool get hasGif => gifUrl.isNotEmpty;
  bool get hasVideo => videoPath.isNotEmpty;

  /// Whether this carries any media at all — what "is there something to
  /// show under the text" means everywhere it is asked.
  bool get hasMedia => hasImage || hasGif || hasVideo;

  /// Whether this repeats another post without adding anything.
  bool get isPlainRepost => repostOf != null && body.isEmpty;

  /// Whether this is a poll. Two answers is the fewest a poll can have, so a
  /// row carrying one is a broken row rather than a poll with one button.
  bool get isPoll => pollOptions.length >= 2;

  /// Whether voting has stopped.
  bool get pollClosed =>
      pollClosesAt != null && !pollClosesAt!.isAfter(DateTime.now());

  /// Whether this account may still vote on it.
  bool get canVote => isPoll && !pollClosed && myVote == null;

  /// Whether the tally is shown rather than the buttons: once you have voted,
  /// or once it is over.
  bool get showPollResults => isPoll && (myVote != null || pollClosed);

  int get pollTotalVotes => pollVotes.fold(0, (a, b) => a + b);

  /// The share of the vote answer [i] holds, 0..1. Zero votes reads as zero
  /// rather than as a division by nothing.
  double pollShare(int i) {
    final total = pollTotalVotes;
    if (total <= 0 || i < 0 || i >= pollVotes.length) return 0;
    return pollVotes[i] / total;
  }

  /// Which answers are winning — plural, because a tie has no single winner
  /// and drawing one would be inventing a result.
  Set<int> get pollLeaders {
    if (!isPoll || pollTotalVotes <= 0) return const {};
    final best = pollVotes.reduce((a, b) => a > b ? a : b);
    return {
      for (var i = 0; i < pollVotes.length; i++)
        if (pollVotes[i] == best) i
    };
  }

  PublicPost copyWith({
    int? likeCount,
    int? replyCount,
    int? repostCount,
    bool? liked,
    bool? mine,
    List<int>? pollVotes,
    int? myVote,
    int? sparkCount,
    int? sparkCents,
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
        gifUrl: gifUrl,
        videoPath: videoPath,
        createdAt: createdAt,
        likeCount: likeCount ?? this.likeCount,
        replyCount: replyCount ?? this.replyCount,
        repostCount: repostCount ?? this.repostCount,
        liked: liked ?? this.liked,
        mine: mine ?? this.mine,
        pollOptions: pollOptions,
        pollClosesAt: pollClosesAt,
        pollVotes: pollVotes ?? this.pollVotes,
        myVote: myVote ?? this.myVote,
        sparkCount: sparkCount ?? this.sparkCount,
        sparkCents: sparkCents ?? this.sparkCents,
        viewCount: viewCount,
      );

  /// The same post with this account's vote removed. A separate method
  /// because copyWith reads null as "leave it alone", so it has no way to say
  /// "back to not voted".
  PublicPost withNoVote() => PublicPost(
        id: id,
        authorUsername: authorUsername,
        authorName: authorName,
        authorVerified: authorVerified,
        body: body,
        replyTo: replyTo,
        repostOf: repostOf,
        imagePath: imagePath,
        gifUrl: gifUrl,
        videoPath: videoPath,
        createdAt: createdAt,
        likeCount: likeCount,
        replyCount: replyCount,
        repostCount: repostCount,
        liked: liked,
        mine: mine,
        pollOptions: pollOptions,
        pollClosesAt: pollClosesAt,
        pollVotes: pollVotes,
        sparkCount: sparkCount,
        sparkCents: sparkCents,
        viewCount: viewCount,
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
        gifUrl: r['gif_url'] as String? ?? '',
        videoPath: r['video_path'] as String? ?? '',
        createdAt: DateTime.tryParse(r['created_at'] as String? ?? '')
                ?.toLocal() ??
            DateTime.now(),
        likeCount: (r['like_count'] as num?)?.toInt() ?? 0,
        replyCount: (r['reply_count'] as num?)?.toInt() ?? 0,
        repostCount: (r['repost_count'] as num?)?.toInt() ?? 0,
        pollOptions: [
          for (final o in (r['poll_options'] as List? ?? const []))
            if (o != null) o.toString()
        ],
        pollClosesAt:
            DateTime.tryParse(r['poll_closes_at'] as String? ?? '')?.toLocal(),
        pollVotes: [
          for (final v in (r['poll_votes'] as List? ?? const []))
            (v as num?)?.toInt() ?? 0
        ],
        sparkCount: (r['spark_count'] as num?)?.toInt() ?? 0,
        sparkCents: (r['spark_cents'] as num?)?.toInt() ?? 0,
        viewCount: (r['view_count'] as num?)?.toInt() ?? 0,
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

  /// What this account passed along. Reposts also stay on Posts (they are
  /// things this person put in front of their followers); this tab is the
  /// same content isolated, for the question "what do they share?".
  reposts,
  media,

  /// Posts this account has LIKED. Only ever shown on your own profile:
  /// the likes table shows nobody's rows but your own, and that privacy is
  /// kept rather than worked around — what somebody else liked is their
  /// business.
  likes,

  /// Posts in the servers this account belongs to. Only ever shown on your own
  /// profile: a server's feed is encrypted with that server's key, so there is
  /// no such thing as seeing a stranger's server posts.
  servers;

  /// The glyph the strip draws. Four words across a phone left each column
  /// about eighty points wide and "Servers" nearly touching its neighbours;
  /// an icon says the same thing in a third of the room, which is why every
  /// timeline that has ever had four tabs uses them.
  IconData get icon => switch (this) {
        // Not a speech bubble: that is the Chats pill in the bar underneath,
        // and the same glyph twice on one screen meaning two different things
        // is worse than a word.
        ProfileTab.posts => Icons.article_outlined,
        ProfileTab.replies => Icons.reply_outlined,
        ProfileTab.reposts => Icons.repeat,
        ProfileTab.media => Icons.image_outlined,
        ProfileTab.likes => Icons.favorite_border,
        ProfileTab.servers => Icons.workspaces_outline,
      };

  String get label => switch (this) {
        ProfileTab.posts => 'Posts',
        ProfileTab.replies => 'Replies',
        ProfileTab.reposts => 'Reposts',
        ProfileTab.media => 'Media',
        ProfileTab.likes => 'Likes',
        ProfileTab.servers => 'Servers',
      };
}

/// How the timeline is narrowed. Two tabs, because two is what the timeline
/// actually has to say: everything, or only the people you chose.
///
/// There used to be a third, "Top", sorting by likes. It was dropped rather
/// than renamed: on a feed this size the most-liked post is often also the
/// newest one, so it showed a near-identical list under a different name —
/// and a tab that looks like the tab beside it is a tab nobody trusts.
enum FeedFilter {
  /// Everything, newest first.
  ///
  /// Called "For you" because that is what it is from the reader's side, not
  /// because anything is ranking it. Nothing here is scored, sorted by
  /// engagement, or chosen on your behalf — it is the whole timeline, newest
  /// first, and the name is the only thing that changed.
  forYou,

  /// Only people you follow (plus yourself), newest first.
  following;

  String get label => switch (this) {
        FeedFilter.forYou => 'For you',
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

  /// Columns read from the `public_feed` view, newest schema first. Named
  /// explicitly and never '*': the underlying table has a phone column that
  /// clients must not select, and asking for everything is how that becomes an
  /// accident.
  ///
  /// WHY THERE IS MORE THAN ONE. The app and the page deploy the moment they
  /// are pushed; the SQL is pasted into a dashboard by hand, whenever somebody
  /// gets to it. So there is always a window where the client asks for columns
  /// the view hasn't got, and asking for one missing column fails the *whole*
  /// request — the feed goes blank, with nothing said about why.
  ///
  /// A timeline without polls is worth far more than no timeline, and one
  /// without reposts or images is worth more than that, so each 42703 steps
  /// down a generation and tries again. This used to be a single boolean,
  /// which could only ever describe two schemas; polls made a third.
  static const List<String> _columnSets = [
    // Current: view counts.
    'id, author_username, author_name, author_verified, body, reply_to, '
        'repost_of, image_path, gif_url, video_path, poll_options, '
        'poll_closes_at, created_at, view_count, like_count, reply_count, '
        'repost_count, poll_votes, spark_count, spark_cents',
    // Before views: sparks.
    'id, author_username, author_name, author_verified, body, reply_to, '
        'repost_of, image_path, gif_url, video_path, poll_options, '
        'poll_closes_at, created_at, like_count, reply_count, repost_count, '
        'poll_votes, spark_count, spark_cents',
    // Before sparks: GIFs and video.
    'id, author_username, author_name, author_verified, body, reply_to, '
        'repost_of, image_path, gif_url, video_path, poll_options, '
        'poll_closes_at, created_at, like_count, reply_count, repost_count, '
        'poll_votes',
    // Before those: polls.
    'id, author_username, author_name, author_verified, body, reply_to, '
        'repost_of, image_path, poll_options, poll_closes_at, created_at, '
        'like_count, reply_count, repost_count, poll_votes',
    // Before polls: reposts and images.
    'id, author_username, author_name, author_verified, body, reply_to, '
        'repost_of, image_path, created_at, like_count, reply_count, '
        'repost_count',
    // The first version of the view.
    'id, author_username, author_name, author_verified, body, reply_to, '
        'created_at, like_count, reply_count',
  ];

  /// Which generation the server turned out to be on. Sticky for the session:
  /// retrying the wide query on every page would double the requests for a
  /// schema that isn't going to change under us.
  int _columnLevel = 0;

  String get _columns => _columnSets[_columnLevel];

  /// The column generations, for a test that checks them against the SQL.
  @visibleForTesting
  static List<String> get debugColumnSets => _columnSets;

  /// Whether the server's feed is behind the app.
  bool get legacyView => _columnLevel > 0;

  /// Whether the server's feed knows about polls.
  bool get pollsSupported => _columnLevel <= 2;

  /// Whether the server's feed knows about GIFs and video. False until the
  /// migration is pasted in — the composer hides both rather than offering a
  /// button whose post the insert would reject.
  bool get mediaSupported => _columnLevel <= 1;

  /// Whether the server's feed carries the spark tallies. False until the
  /// migration is pasted in — the bolt hides rather than offering a tip the
  /// tally could not record.
  bool get sparksSupported => _columnLevel == 0;

  /// Steps down one schema generation. Returns false when there is nothing
  /// older to try, so the caller rethrows rather than looping.
  bool _stepDownSchema() {
    if (_columnLevel >= _columnSets.length - 1) return false;
    _columnLevel++;
    return true;
  }

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
  FeedFilter _filter = FeedFilter.forYou;
  String _query = '';
  String _tag = '';

  FeedFilter get filter => _filter;
  String get query => _query;
  String get tag => _tag;
  bool get loadingMore => _loadingMore;

  /// Whether the last page came back short, meaning there is nothing more.
  bool get reachedEnd => _reachedEnd;

  /// The timeline: top-level posts (never replies), newest first, with muted
  /// authors left out.
  ///
  /// Muting is applied here rather than in the query because it lives on the
  /// device — there is no column for it to filter on. The consequence is that a
  /// page can arrive shorter than it was fetched, which is the right trade: a
  /// mute nobody can see is worth more than a page that is exactly forty long.
  List<PublicPost> get posts {
    final list = _posts
        .where((p) =>
            p.replyTo == null &&
            !FeedMuteStore.instance.isMuted(p.authorUsername) &&
            // The reader's own shape, same rules as the server feeds.
            !FeedPrefs.instance.hides(p.body) &&
            !(FeedPrefs.instance.hideReposts && p.repostOf != null))
        .toList();
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

  /// Test hook: stands in for the network call that casts a vote. The counting
  /// and the refusals around it still run.
  @visibleForTesting
  static Future<void> Function(String postId, int choice)? debugVoteOverride;

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
      {bool hasImage = false,
      bool isRepost = false,
      bool hasGif = false,
      bool hasVideo = false}) {
    final t = text.trim();
    if (t.isEmpty && !hasImage && !isRepost && !hasGif && !hasVideo) {
      return 'Write something first.';
    }
    if (t.length > maxLength) {
      return 'That\'s ${t.length - maxLength} characters too long.';
    }
    return null;
  }

  /// The most answers a poll may have, and the fewest. Matches the CHECK on
  /// the table, so somebody is stopped while typing rather than by a database
  /// error with nothing readable in it.
  static const int minPollOptions = 2;
  static const int maxPollOptions = 4;
  static const int maxPollOptionLength = 40;

  /// How long a poll may run. A week is the longest anybody waits for a
  /// result, and the shortest is short enough to be useful in a conversation.
  static const List<Duration> pollDurations = [
    Duration(hours: 1),
    Duration(hours: 6),
    Duration(days: 1),
    Duration(days: 3),
    Duration(days: 7),
  ];

  /// What is wrong with a set of poll answers, or null when nothing is. Pure,
  /// and the same rules the table's CHECK enforces.
  static String? validatePoll(List<String> options) {
    final filled = [
      for (final o in options)
        if (o.trim().isNotEmpty) o.trim()
    ];
    if (filled.length < minPollOptions) {
      return 'A poll needs at least $minPollOptions answers.';
    }
    if (filled.length > maxPollOptions) {
      return 'A poll can have at most $maxPollOptions answers.';
    }
    for (final o in filled) {
      if (o.length > maxPollOptionLength) {
        return 'Keep each answer under $maxPollOptionLength characters.';
      }
    }
    // Two identical answers make a result nobody can act on.
    final seen = <String>{};
    for (final o in filled) {
      if (!seen.add(o.toLowerCase())) return 'Two answers are the same.';
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
        .select(_columns);
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
      if (isMissingColumn(e.code) && _stepDownSchema()) {
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
    final voted = await _myVotes();
    return [
      for (final r in rows)
        () {
          final post = PublicPost.fromRow(Map<String, dynamic>.from(r as Map));
          return post.copyWith(
            liked: liked.contains(post.id),
            myVote: voted[post.id],
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
        .select(_columns)
        .eq('author_username', username);
    if (before != null) {
      q = q.lt('created_at', before.toUtc().toIso8601String());
    }
    final List<dynamic> rows;
    try {
      rows = await q.order('created_at', ascending: false).limit(limit);
    } on PostgrestException catch (e) {
      if (isMissingColumn(e.code) && _stepDownSchema()) {
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
            .select(_columns)
            .inFilter('id', ids)
            .order('created_at', ascending: false);
        found = await _hydrate(rows);
      } on PostgrestException catch (e) {
        if (isMissingColumn(e.code) && _stepDownSchema()) {
          return postsByIds(ids);
        }
        throw PublicFeedError(_explain(e));
      }
    }
    final present = {for (final p in found) p.id};
    return (found, [for (final id in ids) if (!present.contains(id)) id]);
  }

  /// Test hook: stands in for the replies-of query.
  @visibleForTesting
  static Future<List<PublicPost>> Function(String postId)?
      debugThreadRepliesOverride;

  /// Test hook: stands in for the who-liked RPC.
  @visibleForTesting
  static Future<List<(String, String)>?> Function(String postId)?
      debugLikersOverride;

  /// Test hook: stands in for the who-reposted query.
  @visibleForTesting
  static Future<List<PublicPost>> Function(String postId)?
      debugRepostersOverride;

  /// Who liked [postId] — (username, display name) pairs, newest first.
  ///
  /// Served by `public_post_likers` (docs/public_feed.sql): the likes table
  /// stores phones and hides every row but your own, so this server-side
  /// directory join is the ONE window, and it answers handles only. Null
  /// means the answer is unavailable (the function isn't deployed, or
  /// offline) — which is a different sentence from "nobody liked this".
  /// Likers without a directory row, or with a hidden one, are not listed,
  /// so the like count can honestly exceed the names.
  Future<List<(String, String)>?> likersOf(String postId) async {
    final override = debugLikersOverride;
    if (override != null) return override(postId);
    final client = _client;
    if (client == null) return null;
    try {
      final rows =
          await client.rpc('public_post_likers', params: {'p': postId});
      return [
        for (final r in (rows as List<dynamic>))
          (
            (r as Map)['username'] as String? ?? '',
            r['name'] as String? ?? '',
          )
      ]..removeWhere((e) => e.$1.isEmpty);
    } catch (_) {
      return null;
    }
  }

  /// Test hook: stands in for the own-likes fetch.
  @visibleForTesting
  static Future<List<PublicPost>> Function()? debugLikedPostsOverride;

  /// Test hook: records view reports instead of calling the server.
  @visibleForTesting
  static void Function(String postId)? debugViewedOverride;

  /// Posts already reported viewed this app run — the client's own
  /// discipline against counting one reader as many.
  final Set<String> _viewedReported = {};

  /// Counts one view of [postId], fire-and-forget — once per post per app
  /// run. A tally, not tracking: the call carries the post id and nothing
  /// about the viewer, and the server stores a number, not a row.
  void notePostViewed(String postId) {
    if (postId.isEmpty || !_viewedReported.add(postId)) return;
    final override = debugViewedOverride;
    if (override != null) {
      override(postId);
      return;
    }
    final client = _client;
    if (client == null) return;
    // Best-effort: a view count is never worth an error surface, and a
    // server without the function yet (public_feed.sql not re-run) just
    // doesn't count.
    Future(() async {
      try {
        await client.rpc('public_post_viewed', params: {'p': postId});
      } catch (_) {}
    });
  }

  /// The posts THIS account has liked, newest first — the own-profile
  /// Likes tab. Own likes are the only ones the server lets anyone read,
  /// which is also the only ones a profile should show: what somebody else
  /// liked is their business. A liked post that has since been deleted
  /// simply isn't returned.
  Future<List<PublicPost>> myLikedPosts() async {
    final override = debugLikedPostsOverride;
    if (override != null) return override();
    final ids = (await _myLikes()).toList();
    if (ids.isEmpty) return const [];
    final (found, _) = await postsByIds(ids);
    return found;
  }

  /// Everyone whose repost points at [postId], newest first. A repost is an
  /// ordinary public post, so this is a plain read — nothing to unhide.
  Future<List<PublicPost>> repostersOf(String postId) async {
    final override = debugRepostersOverride;
    if (override != null) return override(postId);
    final client = _client;
    if (client == null) return const [];
    try {
      final rows = await client
          .from('public_feed')
          .select(_columns)
          .eq('repost_of', postId)
          .order('created_at', ascending: false)
          .limit(100);
      return _hydrate(rows);
    } catch (_) {
      return const [];
    }
  }

  /// One post, its replies, and the conversation above it, straight from
  /// the server — the fallback for opening a post the loaded timeline
  /// doesn't hold. A profile reaches months back while the timeline holds
  /// pages, so a local miss says "not loaded here", never "deleted" — only
  /// the server can tell those apart. Null when the post is genuinely gone.
  Future<
      ({
        PublicPost root,
        List<PublicPost> replies,
        List<PublicPost> ancestors
      })?> fetchThread(String postId) async {
    final (roots, _) = await postsByIds([postId]);
    if (roots.isEmpty) return null;
    final root = roots.first;
    // Replies, oldest first — the order a conversation reads in.
    List<PublicPost> replies;
    final repliesOverride = debugThreadRepliesOverride;
    if (repliesOverride != null) {
      replies = await repliesOverride(postId);
    } else {
      final client = _client;
      if (client == null) throw PublicFeedError('No server configured.');
      try {
        final rows = await client
            .from('public_feed')
            .select(_columns)
            .eq('reply_to', postId)
            .order('created_at', ascending: true);
        replies = await _hydrate(rows);
      } on PostgrestException catch (e) {
        if (isMissingColumn(e.code) && _stepDownSchema()) {
          return fetchThread(postId);
        }
        throw PublicFeedError(_explain(e));
      }
    }
    // The chain above, root-first — same depth bound and cycle guard as
    // the local walk in [ancestorsOf].
    final ancestors = <PublicPost>[];
    final seen = <String>{postId};
    var parentId = root.replyTo;
    while (parentId != null && ancestors.length < 10 && seen.add(parentId)) {
      final (found, _) = await postsByIds([parentId]);
      if (found.isEmpty) break;
      ancestors.insert(0, found.first);
      parentId = found.first.replyTo;
    }
    return (root: root, replies: replies, ancestors: ancestors);
  }

  /// A profile's three tabs, from one list of that person's posts. Pure, so
  /// what each tab contains is a rule rather than a query somebody can drift.
  static List<PublicPost> profileTab(List<PublicPost> all, ProfileTab tab) =>
      switch (tab) {
        // Reposts belong on Posts: on a profile they are things this person
        // put in front of their followers, which is what the tab is for.
        ProfileTab.posts => [for (final p in all) if (p.replyTo == null) p],
        ProfileTab.replies => [for (final p in all) if (p.replyTo != null) p],
        ProfileTab.reposts => [for (final p in all) if (p.repostOf != null) p],
        ProfileTab.media => [for (final p in all) if (p.hasImage) p],
        // Likes and server posts come from elsewhere entirely; there is
        // nothing in this person's own posts to filter for them.
        ProfileTab.likes => const [],
        ProfileTab.servers => const [],
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

  /// Which answer this account picked, per poll. Own rows only — the vote
  /// policy hides everyone else's, which is the whole point of a secret
  /// ballot.
  Future<Map<String, int>> _myVotes() async {
    final client = _client;
    if (client == null) return {};
    try {
      final rows =
          await client.from('public_post_votes').select('post_id, choice');
      return {
        for (final r in rows)
          if ((r as Map)['post_id'] is String)
            r['post_id'] as String: (r['choice'] as num?)?.toInt() ?? 0,
      };
    } catch (_) {
      return {}; // unmigrated or offline: nothing shown as voted
    }
  }

  /// Casts a vote. Optimistic: the tally moves at once and is put back if the
  /// server refuses — which it will for a closed poll, a second vote, or an
  /// answer the poll hasn't got, none of which this client is trusted with.
  Future<void> vote(String postId, int choice) async {
    final post = byId(postId);
    if (post == null || !post.canVote) return;
    if (choice < 0 || choice >= post.pollOptions.length) return;

    List<int> bump(List<int> votes, int by) {
      // A tally shorter than the answers means the counter hasn't caught up;
      // pad rather than throw, so a vote is never lost to a rendering detail.
      final next = [
        for (var i = 0; i < post.pollOptions.length; i++)
          i < votes.length ? votes[i] : 0
      ];
      next[choice] = (next[choice] + by).clamp(0, 1 << 30);
      return next;
    }

    final before = post.pollVotes;
    _apply(postId,
        (p) => p.copyWith(pollVotes: bump(p.pollVotes, 1), myVote: choice));

    final override = debugVoteOverride;
    try {
      if (override != null) {
        await override(postId, choice);
        return;
      }
      final client = _client;
      final phone = local.Session.instance.user.value?.phone ?? '';
      if (client == null || phone.isEmpty) {
        throw PublicFeedError('Sign in to vote.');
      }
      await client.from('public_post_votes').insert({
        'post_id': postId,
        'voter_phone': AccountService.e164(phone),
        'choice': choice,
      });
    } catch (_) {
      // Put it back. A vote that silently didn't count is worse than one that
      // visibly bounced, and there is no way to cast it again to find out.
      _apply(postId, (p) => p.copyWith(pollVotes: before).withNoVote());
    }
  }

  /// The chain of posts [postId] is a reply to, ROOT FIRST.
  ///
  /// This is what makes a thread a thread rather than a stack of screens: X
  /// draws the conversation above the post you opened, and without it a reply
  /// four levels down is a sentence with no idea what it is answering.
  ///
  /// Bounded and cycle-safe, and not defensively — a post's parent id arrives
  /// over the relay from somebody else's device. A row pointing at itself, or
  /// a pair pointing at each other, is one malformed message away, and an
  /// unbounded walk up would hang the thread screen rather than render it.
  /// Anything past [maxThreadDepth] is a conversation nobody is reading in
  /// one screenful anyway.
  static const int maxThreadDepth = 25;

  List<PublicPost> ancestorsOf(String postId) {
    final chain = <PublicPost>[];
    final seen = <String>{postId};
    var current = byId(postId);
    while (current?.replyTo != null && chain.length < maxThreadDepth) {
      final parentId = current!.replyTo!;
      if (!seen.add(parentId)) break; // a loop: stop rather than spin
      final parent = byId(parentId);
      if (parent == null) break; // not loaded (or deleted) — say no more
      chain.add(parent);
      current = parent;
    }
    return chain.reversed.toList();
  }

  /// The author's own replies to [postId], oldest first — a self-thread.
  ///
  /// Somebody continuing their own post is a different thing from strangers
  /// answering it: it is one piece of writing that ran past a post's length,
  /// so the timeline offers to open it rather than leaving the rest of the
  /// sentence somewhere you have to go looking. Replies BY OTHERS are not
  /// this, and the count on the card already covers them.
  List<PublicPost> selfThreadOf(String postId) {
    final root = byId(postId);
    if (root == null) return const [];
    return [
      for (final p in _posts)
        if (p.replyTo == postId && p.authorUsername == root.authorUsername) p
    ].reversed.toList();
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
  /// Asks the server to screen [text] before it goes up, and returns the
  /// reason it must not when there is one.
  ///
  /// The feed is public, so unlike everything else people write here this can
  /// go to a hosted model without breaking the encryption promise — see
  /// supabase/functions/moderation-screen. It is a speed bump, not a gate: the
  /// client makes this call, so a modified client skips it. Enforcement is
  /// still reports and sanctions.
  ///
  /// FAILS OPEN, ALWAYS. No key configured, no network, function not
  /// deployed, server having a bad day — all of them return null and the post
  /// goes up. Somebody's post must never be lost to our own outage.
  Future<String?> screen(String text, {bool hasImage = false}) async {
    Map<dynamic, dynamic>? answer;
    try {
      // The override stands in for the CALL, not for this method — so the
      // fail-open handling below is the same code in a test as on a phone.
      // An override that replaced the whole method would leave every one of
      // these branches covered by nothing, which is exactly the code that
      // must not be wrong.
      final override = debugScreenOverride;
      if (override != null) {
        answer = await override(text);
      } else {
        final client = _client;
        if (client == null) return null;
        final me = AppState.profile.value;
        final res = await client.functions.invoke('moderation-screen', body: {
          'text': text.trim(),
          'handle': me.username,
          'hasImage': hasImage,
        });
        if (res.status >= 400) return null;
        final data = res.data;
        answer = data is Map ? data : null;
      }
    } catch (_) {
      // Offline, not deployed, a gateway having a bad day.
      return null;
    }
    if (answer == null) return null;
    if (answer['verdict'] != 'block') return null;
    final reason = (answer['reason'] as String?)?.trim() ?? '';
    // A block with no explanation would be a door with no sign on it.
    return reason.isEmpty
        ? 'That post looks like it breaks the rules for the public feed.'
        : reason;
  }

  /// Stands in for the screening call's raw answer — null for every way it
  /// can fail, or the function's own JSON body.
  @visibleForTesting
  static Future<Map<dynamic, dynamic>?> Function(String text)?
      debugScreenOverride;

  Future<void> post(String text,
      {String? replyTo,
      String? repostOf,
      Uint8List? image,
      String? gifUrl,
      Uint8List? video,
      List<String>? pollOptions,
      Duration? pollRunsFor}) async {
    final problem = validate(text,
        hasImage: image != null,
        isRepost: repostOf != null,
        hasGif: (gifUrl ?? '').isNotEmpty,
        hasVideo: video != null);
    if (problem != null) throw PublicFeedError(problem);
    // One piece of media. Two would have to share the width, and the second
    // would be a thumbnail nobody asked for — the same reason a poll and a
    // photo have never been allowed together.
    final carried = [
      image != null,
      (gifUrl ?? '').isNotEmpty,
      video != null,
    ].where((x) => x).length;
    if (carried > 1) {
      throw PublicFeedError('One picture, GIF or video per post.');
    }
    if (replyTo != null && repostOf != null) {
      // The table refuses this too; catching it here keeps the message useful.
      throw PublicFeedError('A post can be a reply or a repost, not both.');
    }
    // A poll is a top-level post with a question. Each of these is a CHECK on
    // the table as well; saying it here is what makes the refusal readable.
    final answers = pollOptions == null
        ? const <String>[]
        : [
            for (final o in pollOptions)
              if (o.trim().isNotEmpty) o.trim()
          ];
    if (answers.isNotEmpty) {
      final wrong = validatePoll(answers);
      if (wrong != null) throw PublicFeedError(wrong);
      if (replyTo != null || repostOf != null) {
        throw PublicFeedError('A poll has to be a post of its own.');
      }
      if (text.trim().isEmpty) throw PublicFeedError('Ask a question first.');
    }
    final closesAt = answers.isEmpty
        ? null
        : DateTime.now().add(pollRunsFor ?? const Duration(days: 1));
    final me = AppState.profile.value;
    final phone = local.Session.instance.user.value?.phone ?? me.phone;
    if (phone.trim().isEmpty) {
      throw PublicFeedError('Sign in to post.');
    }
    // Before the image upload, so a blocked post leaves nothing behind in
    // the bucket to sweep up later. The answers are screened with the
    // question: they are public text on a public post, and a poll whose
    // answers went unread would be the obvious way round the screening.
    final blocked = await screen([text, ...answers].join('\n'),
        hasImage: image != null);
    if (blocked != null) throw PublicFeedError(blocked);

    final id = newId();
    // The image goes up first: a post pointing at an object that failed to
    // upload would render a broken box for everyone, forever.
    var imagePath = '';
    if (image != null) {
      imagePath = await _uploadImage(id, image);
    }
    var videoPath = '';
    if (video != null) {
      videoPath = await _uploadVideo(id, video);
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
      gifUrl: gifUrl ?? '',
      videoPath: videoPath,
      createdAt: DateTime.now(),
      mine: true,
      pollOptions: answers,
      pollClosesAt: closesAt,
      // Nobody has voted yet, and an empty tally would render as no bars at
      // all rather than as a row of zeroes.
      pollVotes: [for (final _ in answers) 0],
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
          if (post.gifUrl.isNotEmpty) 'gif_url': post.gifUrl,
          if (videoPath.isNotEmpty) 'video_path': videoPath,
          if (answers.isNotEmpty) 'poll_options': answers,
          if (closesAt != null)
            'poll_closes_at': closesAt.toUtc().toIso8601String(),
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

  /// The biggest video a public post may carry.
  ///
  /// The same 12 MB a marketplace listing gets, and for the same reason: it
  /// is about thirty seconds of 720p phone video, and a cap is what makes any
  /// claim about the cost of hosting this true. Storage is the cheap half
  /// ($0.0213/GB-mo); egress is the half that scales with how popular a post
  /// gets, and on a WORLD-READABLE feed that has no ceiling. Twelve megabytes
  /// is the difference between a post that goes around costing cents and one
  /// costing tens of dollars.
  static const int maxVideoBytes = 12 * 1024 * 1024;

  /// Where to fetch a post's video from, or null when it has none.
  ///
  /// A plain public URL, so the player streams it straight from the bucket —
  /// no download-then-decrypt step, which is what limits a *server* feed's
  /// video to devices with a filesystem. This one plays on the web too.
  static String? videoUrlFor(PublicPost post) {
    if (!post.hasVideo || !RelayConfig.isEnabled) return null;
    return '${RelayConfig.supabaseUrl}/storage/v1/object/public/'
        '$bucket/${post.videoPath}';
  }

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

  /// Test hook: replaces the video bucket round trip.
  @visibleForTesting
  static Future<String> Function(String id, Uint8List bytes)?
      debugUploadVideoOverride;

  /// Puts a video in the bucket and returns its object name.
  ///
  /// Unsealed, unlike a listing's. A public post is world-readable, so there
  /// is nobody to keep the bytes from, and encrypting with a key everybody
  /// holds costs CPU to protect nothing. It also means the player streams the
  /// URL directly — which is what lets this work on the web, where a listing
  /// video cannot (no filesystem to decrypt into).
  Future<String> _uploadVideo(String id, Uint8List bytes) async {
    if (bytes.length > maxVideoBytes) {
      throw PublicFeedError(
          'That video is over ${maxVideoBytes ~/ (1024 * 1024)} MB. '
          'About 30 seconds fits — trim it and try again.');
    }
    if (!MarketMedia.looksLikeVideo(bytes)) {
      // Reusing the marketplace's container sniff rather than a second copy
      // of the same magic numbers.
      throw PublicFeedError('That doesn\'t look like a video file.');
    }
    final override = debugUploadVideoOverride;
    if (override != null) return override(id, bytes);
    final client = _client;
    if (client == null) throw PublicFeedError('No server configured.');
    final name = '$id.mp4';
    try {
      await client.storage.from(bucket).uploadBinary(name, bytes,
          fileOptions: const FileOptions(contentType: 'video/mp4'));
      return name;
    } catch (e) {
      final text = '$e';
      if (text.contains('Bucket not found')) {
        throw PublicFeedError('Video posting isn\'t set up on the server yet.'
            '\n\n(re-run docs/public_feed.sql)');
      }
      if (text.contains('exceeded the maximum allowed size') ||
          text.contains('Payload too large')) {
        // The bucket has its own ceiling and it may be lower than ours.
        throw PublicFeedError('The server refused that video for its size.');
      }
      throw PublicFeedError('Couldn\'t upload that video.');
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

  /// Posts this device sparked, this session — what lights the bolt amber.
  final Set<String> _sparkedIds = {};
  bool sparkedByMe(String postId) => _sparkedIds.contains(postId);

  /// Records MY spark, called only AFTER its payment succeeded: bumps the
  /// tally on the local copy and writes the tally row. In payments test mode
  /// nothing is written — a simulated payment must not move a real,
  /// world-readable tally — so the bump stays on this device.
  Future<void> recordSpark(String postId, int cents) async {
    if (cents <= 0) return;
    _sparkedIds.add(postId);
    _apply(
        postId,
        (p) => p.copyWith(
            sparkCount: p.sparkCount + 1, sparkCents: p.sparkCents + cents));
    if (PaymentService.instance.testMode.value) return;
    try {
      final client = _client;
      final phone = local.Session.instance.user.value?.phone ?? '';
      if (client == null || phone.isEmpty) return;
      await client.from('public_post_sparks').insert({
        'post_id': postId,
        'sparker_phone': AccountService.e164(phone),
        'cents': cents,
      });
    } catch (_) {
      // The MONEY moved; a tally row that bounced is not worth alarming
      // anyone over. The counters recount from the table on the next fetch.
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
    debugVoteOverride = null;
    debugUploadOverride = null;
    debugProfileOverride = null;
    debugByIdsOverride = null;
    debugThreadRepliesOverride = null;
    debugLikersOverride = null;
    debugRepostersOverride = null;
    debugLikedPostsOverride = null;
    debugViewedOverride = null;
    _viewedReported.clear();
    _filter = FeedFilter.forYou;
    _query = '';
    _tag = '';
    _reachedEnd = false;
    _loadingMore = false;
    _columnLevel = 0;
    notifyListeners();
  }
}

/// A count the way X writes one: raw under a thousand, then '1.2K',
/// '45K', '3.4M' — one decimal only while it still means anything. Pure.
String compactCount(int n) {
  if (n < 1000) return '$n';
  if (n < 10000) {
    final tenths = (n / 100).floor();
    return tenths % 10 == 0 ? '${tenths ~/ 10}K' : '${tenths / 10}K';
  }
  if (n < 1000000) return '${(n / 1000).floor()}K';
  final tenths = (n / 100000).floor();
  return tenths % 10 == 0 ? '${tenths ~/ 10}M' : '${tenths / 10}M';
}
