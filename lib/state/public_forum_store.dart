import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../app_state.dart';
import '../models/community.dart' show forumTags;
import '../relay/relay_config.dart';
import 'account_service.dart';
import 'public_feed_store.dart';
import 'score_store.dart';
import 'session.dart' as local;

/// How posts are ordered on the public forum.
enum PublicForumSort { hot, fresh, top }

/// One post on the public forum — a world-readable, Reddit-shaped board that
/// lives outside any server. Attribution is by username; the author's phone is
/// never on the wire (the view carries no phone column), exactly like the
/// public feed.
@immutable
class PublicForumPost {
  final String id;
  final String authorUsername;
  final String authorName;
  final bool authorVerified;
  final String title;
  final String body;
  final String tag;

  /// The section (subreddit-style board) slug this post lives in, or '' for
  /// the default "General" board.
  final String section;
  final String gifUrl;
  final String imagePath;
  final DateTime createdAt;

  /// Sum of the up/down votes.
  final int score;
  final int commentCount;

  /// -1, 0 or 1 — how THIS device voted, filled in from the votes table.
  final int myVote;

  /// True when this account is the author (by username, the only thing the
  /// view can honestly compare — the phone column is not readable).
  final bool mine;

  const PublicForumPost({
    required this.id,
    required this.authorUsername,
    required this.authorName,
    this.authorVerified = false,
    required this.title,
    this.body = '',
    this.tag = '',
    this.section = '',
    this.gifUrl = '',
    this.imagePath = '',
    required this.createdAt,
    this.score = 0,
    this.commentCount = 0,
    this.myVote = 0,
    this.mine = false,
  });

  PublicForumPost copyWith({
    int? score,
    int? commentCount,
    int? myVote,
    bool? mine,
  }) =>
      PublicForumPost(
        id: id,
        authorUsername: authorUsername,
        authorName: authorName,
        authorVerified: authorVerified,
        title: title,
        body: body,
        tag: tag,
        section: section,
        gifUrl: gifUrl,
        imagePath: imagePath,
        createdAt: createdAt,
        score: score ?? this.score,
        commentCount: commentCount ?? this.commentCount,
        myVote: myVote ?? this.myVote,
        mine: mine ?? this.mine,
      );

  /// The full public URL for [imagePath], or '' when there is no image. Shared
  /// world-readable public-media bucket with the public feed, so the object is
  /// reachable at the same storage path shape.
  String get imageUrl => (imagePath.isEmpty || !RelayConfig.isEnabled)
      ? ''
      : '${RelayConfig.supabaseUrl}/storage/v1/object/public/'
          'public-media/$imagePath';

  factory PublicForumPost.fromRow(Map<String, dynamic> r) => PublicForumPost(
        id: r['id'] as String,
        authorUsername: r['author_username'] as String? ?? '',
        authorName: r['author_name'] as String? ?? '',
        authorVerified: r['author_verified'] as bool? ?? false,
        title: r['title'] as String? ?? '',
        body: r['body'] as String? ?? '',
        tag: r['tag'] as String? ?? '',
        section: r['section'] as String? ?? '',
        gifUrl: r['gif_url'] as String? ?? '',
        imagePath: r['image_path'] as String? ?? '',
        createdAt:
            DateTime.tryParse(r['created_at'] as String? ?? '')?.toLocal() ??
                DateTime.now(),
        score: (r['score'] as num?)?.toInt() ?? 0,
        commentCount: (r['comment_count'] as num?)?.toInt() ?? 0,
      );
}

/// One comment on a public forum post. Flat rows carrying a [parentId]; the
/// screen walks them into a shallow tree, like both newsfeeds.
@immutable
class PublicForumComment {
  final String id;
  final String postId;
  final String authorUsername;
  final String authorName;
  final bool authorVerified;
  final String body;
  final String gifUrl;
  final String? parentId;
  final DateTime createdAt;
  final bool mine;

  /// Net votes. Reddit's whole comment layer hangs off this; the forum
  /// shipped without it, so a good answer three replies down had no way to
  /// rise. Defaults to 0 so a project that has not run the votes migration
  /// yet renders a working thread rather than an error.
  final int score;

  /// This device's vote: 1, -1 or 0.
  final int myVote;

  const PublicForumComment({
    required this.id,
    required this.postId,
    required this.authorUsername,
    required this.authorName,
    this.authorVerified = false,
    this.body = '',
    this.gifUrl = '',
    this.parentId,
    required this.createdAt,
    this.mine = false,
    this.score = 0,
    this.myVote = 0,
  });

  PublicForumComment copyWith({int? score, int? myVote}) =>
      PublicForumComment(
        id: id,
        postId: postId,
        authorUsername: authorUsername,
        authorName: authorName,
        authorVerified: authorVerified,
        body: body,
        gifUrl: gifUrl,
        parentId: parentId,
        createdAt: createdAt,
        mine: mine,
        score: score ?? this.score,
        myVote: myVote ?? this.myVote,
      );

  factory PublicForumComment.fromRow(Map<String, dynamic> r) =>
      PublicForumComment(
        id: r['id'] as String,
        postId: r['post_id'] as String? ?? '',
        authorUsername: r['author_username'] as String? ?? '',
        authorName: r['author_name'] as String? ?? '',
        authorVerified: r['author_verified'] as bool? ?? false,
        body: r['body'] as String? ?? '',
        gifUrl: r['gif_url'] as String? ?? '',
        parentId: r['parent_id'] as String?,
        createdAt:
            DateTime.tryParse(r['created_at'] as String? ?? '')?.toLocal() ??
                DateTime.now(),
        score: (r['score'] as num?)?.toInt() ?? 0,
      );
}

/// A subreddit-style board anyone signed in can create. [slug] is the id
/// (lowercase letters/digits/underscore); [title] is what shows.
@immutable
class PublicForumSection {
  final String slug;
  final String title;
  final String description;

  const PublicForumSection({
    required this.slug,
    this.title = '',
    this.description = '',
  });

  /// What to show on a chip/header — the title, or the slug if unnamed.
  String get label => title.trim().isEmpty ? slug : title.trim();

  factory PublicForumSection.fromRow(Map<String, dynamic> r) =>
      PublicForumSection(
        slug: r['slug'] as String? ?? '',
        title: r['title'] as String? ?? '',
        description: r['description'] as String? ?? '',
      );

  /// Turns a free-typed name into a valid slug (lowercase, a–z/0–9/_ only,
  /// 2–24 chars). Returns '' when nothing usable is left.
  static String slugify(String raw) {
    final s = raw
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    if (s.length < 2) return '';
    return s.length > 24 ? s.substring(0, 24) : s;
  }
}

/// Raised for a problem the composer can show as-is.
class PublicForumError implements Exception {
  final String message;
  PublicForumError(this.message);
  @override
  String toString() => message;
}

/// The world-readable public forum. Modelled on [PublicFeedStore]: reads are
/// served by the anon key (a name-only account may browse), every write needs a
/// session, and moderation runs at post time through the same speed bump.
class PublicForumStore extends ChangeNotifier {
  PublicForumStore._();
  static final PublicForumStore instance = PublicForumStore._();

  static const int pageSize = 30;
  static const int maxTitle = 140;
  static const int maxBody = 4000;

  List<PublicForumPost> _posts = [];
  List<PublicForumPost> get posts => _sorted(_posts);
  PublicForumSort _sort = PublicForumSort.hot;
  PublicForumSort get sort => _sort;
  String _tag = '';
  String get tag => _tag;

  /// The section (board) being browsed, '' = All / General combined.
  String _section = '';
  String get sectionFilter => _section;

  /// Every section this device knows about, for the picker.
  List<PublicForumSection> _sections = [];
  List<PublicForumSection> get sections => List.unmodifiable(_sections);

  bool _loading = false;
  bool get loading => _loading;
  bool _more = true;
  bool get hasMore => _more;

  SupabaseClient? get _client {
    if (!RelayConfig.isEnabled) return null;
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  // ---- test seams (mirror PublicFeedStore) -------------------------------
  @visibleForTesting
  static Future<List<PublicForumPost>> Function()? debugLoadOverride;
  @visibleForTesting
  static Future<void> Function(PublicForumPost post)? debugPostOverride;
  @visibleForTesting
  static Future<void> Function(String postId, int dir)? debugVoteOverride;
  @visibleForTesting
  static Future<void> Function(String commentId, int dir)?
      debugCommentVoteOverride;
  @visibleForTesting
  static Future<List<PublicForumComment>> Function(String postId)?
      debugCommentsOverride;
  @visibleForTesting
  static Future<void> Function(String postId, PublicForumComment c)?
      debugCommentOverride;
  @visibleForTesting
  static Future<List<PublicForumSection>> Function()? debugSectionsOverride;
  @visibleForTesting
  static Future<void> Function(PublicForumSection s)? debugCreateSectionOverride;

  @visibleForTesting
  void debugSetPosts(List<PublicForumPost> posts) {
    _posts = List.of(posts);
    notifyListeners();
  }

  @visibleForTesting
  void debugSetSections(List<PublicForumSection> s) {
    _sections = List.of(s);
    notifyListeners();
  }

  @visibleForTesting
  void resetForTest() {
    _posts = [];
    _sections = [];
    _sort = PublicForumSort.hot;
    _tag = '';
    _section = '';
    _loading = false;
    _more = true;
    debugLoadOverride = null;
    debugPostOverride = null;
    debugVoteOverride = null;
    debugCommentVoteOverride = null;
    debugCommentsOverride = null;
    debugCommentOverride = null;
    debugSectionsOverride = null;
    debugCreateSectionOverride = null;
    debugSignedOutOverride = null;
  }

  /// A post id nobody else will generate.
  static String newId() {
    final rng = Random.secure();
    final n = List<int>.generate(8, (_) => rng.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return 'fp_$n';
  }

  static String _commentId() {
    final rng = Random.secure();
    final n = List<int>.generate(8, (_) => rng.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return 'fc_$n';
  }

  List<PublicForumPost> _sorted(List<PublicForumPost> src) {
    final list = [
      for (final p in src)
        if ((_tag.isEmpty || p.tag == _tag) &&
            (_section.isEmpty || p.section == _section))
          p
    ];
    switch (_sort) {
      case PublicForumSort.fresh:
        list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        break;
      case PublicForumSort.top:
        list.sort((a, b) => b.score.compareTo(a.score));
        break;
      case PublicForumSort.hot:
        // Reddit-lite: score dampened by age, so a fresh post can out-rank an
        // old high-scorer but a runaway score still wins.
        double hot(PublicForumPost p) {
          final ageHours =
              DateTime.now().difference(p.createdAt).inMinutes / 60.0;
          return p.score - ageHours / 6.0;
        }

        list.sort((a, b) => hot(b).compareTo(hot(a)));
        break;
    }
    return list;
  }

  Future<void> setSort(PublicForumSort s) async {
    if (_sort == s) return;
    _sort = s;
    notifyListeners();
  }

  Future<void> setTag(String t) async {
    if (_tag == t) return;
    _tag = t;
    notifyListeners();
  }

  /// Browse one section (a slug), or '' for all. Reloads so a section with more
  /// than a page of posts fills in from the server, not just what's in memory.
  Future<void> setSectionFilter(String slug) async {
    if (_section == slug) return;
    _section = slug;
    notifyListeners();
    await load();
  }

  /// The display label for the current section filter ('' → "All").
  String get sectionLabel {
    if (_section.isEmpty) return 'All';
    for (final s in _sections) {
      if (s.slug == _section) return s.label;
    }
    return _section;
  }

  /// Loads the list of sections (subreddit-style boards). Best-effort.
  Future<void> loadSections() async {
    final override = debugSectionsOverride;
    if (override != null) {
      _sections = await override();
      notifyListeners();
      return;
    }
    final client = _client;
    if (client == null) return;
    try {
      final rows = await client
          .from('public_forum_sections')
          .select('slug, title, description')
          .order('created_at', ascending: false)
          .limit(200);
      _sections = [
        for (final r in rows)
          PublicForumSection.fromRow(Map<String, dynamic>.from(r as Map))
      ];
      notifyListeners();
    } catch (_) {
      // Unmigrated or offline: no sections, just the General board.
    }
  }

  /// Creates a new section. Requires a session (numberless is refused, like
  /// posting). Returns the created section; throws a [PublicForumError] the
  /// sheet can show.
  Future<PublicForumSection> createSection(String title,
      {String description = ''}) async {
    final slug = PublicForumSection.slugify(title);
    if (slug.isEmpty) {
      throw PublicForumError(
          'Give the section a name (letters or numbers, 2+ characters).');
    }
    if (_sections.any((s) => s.slug == slug)) {
      throw PublicForumError('A section called "$slug" already exists.');
    }
    final me = AppState.profile.value;
    final phone = local.Session.instance.user.value?.phone ?? me.phone;
    if (phone.trim().isEmpty) throw PublicForumError('Sign in first.');
    if (local.Session.instance.isNumberless) {
      throw PublicForumError('Creating a section needs a phone number.');
    }
    // A phone account whose Supabase session has lapsed is a DIFFERENT state
    // from a name-only one, and it used to be indistinguishable: the write
    // went out as `anon`, Postgres answered "permission denied" (the grants
    // are `to authenticated`), and that surfaced as "Couldn't reach the
    // forum. Try again." Caught here, nothing is sent and the sentence is
    // the one thing that helps.
    if (signedOutOfServer) throw PublicForumError(_signedOut);
    final section = PublicForumSection(
        slug: slug, title: title.trim(), description: description.trim());
    final override = debugCreateSectionOverride;
    if (override != null) {
      await override(section);
    } else {
      final client = _client;
      if (client == null) throw PublicForumError('No server configured.');
      try {
        await client.from('public_forum_sections').insert({
          'slug': section.slug,
          'title': section.title,
          if (section.description.isNotEmpty) 'description': section.description,
          'created_by_phone': AccountService.e164(phone),
        });
      } catch (e) {
        throw PublicForumError(_explain(e));
      }
    }
    _sections = [section, ..._sections];
    notifyListeners();
    return section;
  }

  /// Trims and checks a new post. Null when fine, else the reason. Pure.
  static String? validate(String title, String body,
      {bool hasMedia = false}) {
    final t = title.trim();
    if (t.isEmpty) return 'Give your post a title.';
    if (t.length > maxTitle) return 'Keep the title under $maxTitle characters.';
    if (body.trim().length > maxBody) {
      return 'Keep the post under $maxBody characters.';
    }
    return null;
  }

  Future<void> load({int limit = pageSize}) async {
    _loading = true;
    notifyListeners();
    try {
      _posts = await _fetch(limit: limit, before: null);
      _more = _posts.length >= limit;
    } catch (_) {
      // Offline / not deployed: keep whatever is on screen.
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> loadMore() async {
    if (_loading || !_more || _posts.isEmpty) return;
    _loading = true;
    notifyListeners();
    try {
      final oldest = _posts
          .map((p) => p.createdAt)
          .reduce((a, b) => a.isBefore(b) ? a : b);
      final next = await _fetch(limit: pageSize, before: oldest);
      final seen = _posts.map((p) => p.id).toSet();
      _posts = [..._posts, ...next.where((p) => !seen.contains(p.id))];
      _more = next.length >= pageSize;
    } catch (_) {
      // Leave the list as it is.
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<List<PublicForumPost>> _fetch(
      {required int limit, required DateTime? before}) async {
    final override = debugLoadOverride;
    if (override != null) return override();
    final client = _client;
    if (client == null) throw PublicForumError('No server configured.');
    var q = client.from('public_forum').select(
        'id, author_username, author_name, author_verified, title, body, '
        'tag, section, gif_url, image_path, created_at, edited_at, score, '
        'comment_count');
    // A chosen section narrows server-side, so browsing a board pages through
    // that board and not the whole forum.
    if (_section.isNotEmpty) {
      q = q.eq('section', _section);
    }
    if (before != null) {
      q = q.lt('created_at', before.toUtc().toIso8601String());
    }
    final rows = await q.order('created_at', ascending: false).limit(limit);
    return _hydrate(rows);
  }

  Future<List<PublicForumPost>> _hydrate(List<dynamic> rows) async {
    final mineUsername = AppState.profile.value.username;
    final voted = await _myVotes();
    return [
      for (final r in rows)
        () {
          final post =
              PublicForumPost.fromRow(Map<String, dynamic>.from(r as Map));
          return post.copyWith(
            myVote: voted[post.id] ?? 0,
            mine: mineUsername.isNotEmpty &&
                post.authorUsername == mineUsername,
          );
        }(),
    ];
  }

  Future<Map<String, int>> _myVotes() async {
    final client = _client;
    if (client == null) return {};
    try {
      final rows =
          await client.from('public_forum_votes').select('post_id, dir');
      return {
        for (final r in rows)
          if ((r as Map)['post_id'] is String)
            r['post_id'] as String: (r['dir'] as num?)?.toInt() ?? 0,
      };
    } catch (_) {
      return {};
    }
  }

  /// Test hook: replaces the image bucket round trip.
  @visibleForTesting
  static Future<String> Function(String id, Uint8List bytes)?
      debugUploadOverride;

  static const int maxImageBytes = 4 * 1024 * 1024;

  /// Puts a post image in the shared world-readable public-media bucket and
  /// returns its object name. Unsealed, like a public feed image — a public
  /// post has nobody to keep the bytes from.
  Future<String> _uploadImage(String id, Uint8List bytes) async {
    if (bytes.length > maxImageBytes) {
      throw PublicForumError('That image is over '
          '${maxImageBytes ~/ (1024 * 1024)} MB. Pick a smaller one.');
    }
    final override = debugUploadOverride;
    if (override != null) return override(id, bytes);
    final client = _client;
    if (client == null) throw PublicForumError('No server configured.');
    final name = '$id.jpg';
    try {
      await client.storage.from('public-media').uploadBinary(name, bytes,
          fileOptions: const FileOptions(contentType: 'image/jpeg'));
      return name;
    } catch (e) {
      if ('$e'.contains('Bucket not found')) {
        throw PublicForumError(
            'Image posting isn\'t set up on the server yet.'
            '\n\n(re-run docs/public_feed.sql)');
      }
      throw PublicForumError('Couldn\'t upload that image.');
    }
  }

  /// There IS a server, and this device is not signed in to it.
  ///
  /// Every forum WRITE is granted `to authenticated` only, so without a
  /// session the request goes out as `anon` and Postgres answers `42501
  /// permission denied for table …` — before RLS is even consulted. Reads
  /// keep working (served to `anon` by design), which is why a lapsed
  /// session shows a perfectly normal board where nothing can be voted on,
  /// posted to or commented on.
  ///
  /// False when there is NO client, deliberately: a build with no relay has
  /// no server to be signed out OF, and the write paths already answer that
  /// case with "No server configured." Saying "you are signed out" there
  /// would be a second wrong sentence rather than a fix for the first.
  bool get signedOutOfServer {
    final override = debugSignedOutOverride;
    if (override != null) return override;
    final client = _client;
    if (client == null) return false;
    return client.auth.currentSession == null;
  }

  /// Test seam — there is no Supabase client in the suite, so the branch
  /// could not otherwise be exercised in either direction.
  @visibleForTesting
  static bool? debugSignedOutOverride;

  /// What actually went wrong, said plainly.
  ///
  /// This used to answer "Couldn't reach the forum. Try again." to
  /// EVERYTHING, which is the most misleading sentence available: it names
  /// the network and asks for a retry, and the common causes are neither
  /// transient nor retryable. A signed-out device — the one that produces
  /// most of these — would retry forever.
  String _explain(Object e) {
    final s = e.toString();
    // A missing table reads as a server that has not been migrated, not as a
    // fault of the person tapping the button.
    if (s.contains('PGRST205') ||
        s.contains('42P01') ||
        s.contains('does not exist')) {
      return 'The forum isn\'t set up on the server yet.';
    }
    // RLS refused the ROW: the account exists and may write, but not this
    // one. This is the only case that is genuinely about the account.
    if (s.contains('is_silenced') || s.contains('row-level security')) {
      return 'Your account can\'t post right now.';
    }
    // The GRANT refused the table. Signed out, that is the ordinary anon
    // refusal. Signed IN, it is not the account's fault at all — it means a
    // privilege is missing from the schema, and saying "your account can't
    // post" sends somebody looking at their own standing for a server bug.
    // That is exactly what happened with down-votes: `on conflict
    // (post_id, voter_phone)` needs SELECT on the conflict target, the
    // column was withheld, and every downvote read as a moderation problem.
    if (s.contains('42501') || s.contains('permission denied')) {
      return signedOutOfServer
          ? _signedOut
          : 'The forum isn\'t set up correctly on the server.';
    }
    if (signedOutOfServer) return _signedOut;
    return 'Couldn\'t reach the forum. Try again.';
  }

  /// Said in one place because every write path and [_explain] reach it, and
  /// because a retry is exactly the wrong advice.
  static const String _signedOut =
      'You\'re signed out of the server. Sign in again to post, vote or '
      'comment here.';

  /// Creates a top-level forum post. Requires a session (a name-only account is
  /// refused, like the public feed); the text is moderation-screened first.
  Future<PublicForumPost> post({
    required String title,
    String body = '',
    String tag = '',
    String section = '',
    String? gifUrl,
    Uint8List? image,
  }) async {
    final problem =
        validate(title, body, hasMedia: image != null || (gifUrl ?? '').isNotEmpty);
    if (problem != null) throw PublicForumError(problem);
    final me = AppState.profile.value;
    final phone = local.Session.instance.user.value?.phone ?? me.phone;
    if (phone.trim().isEmpty) throw PublicForumError('Sign in to post.');
    if (local.Session.instance.isNumberless) {
      throw PublicForumError('Posting needs a phone number.');
    }
    // A phone account whose Supabase session has lapsed is a DIFFERENT state
    // from a name-only one, and it used to be indistinguishable: the write
    // went out as `anon`, Postgres answered "permission denied" (the grants
    // are `to authenticated`), and that surfaced as "Couldn't reach the
    // forum. Try again." Caught here, nothing is sent and the sentence is
    // the one thing that helps.
    if (signedOutOfServer) throw PublicForumError(_signedOut);
    // Same speed bump the public feed uses; fails open when the function is
    // offline. Screens title and body together — the title is public text too.
    final blocked =
        await PublicFeedStore.instance.screen('$title\n$body', hasImage: image != null);
    if (blocked != null) throw PublicForumError(blocked);

    final id = newId();
    var imagePath = '';
    if (image != null) {
      imagePath = await _uploadImage(id, image);
    }
    final created = PublicForumPost(
      id: id,
      authorUsername: me.username,
      authorName: me.name,
      authorVerified: me.verified,
      title: title.trim(),
      body: body.trim(),
      tag: forumTags.contains(tag) ? tag : '',
      section: PublicForumSection.slugify(section),
      gifUrl: gifUrl ?? '',
      imagePath: imagePath,
      createdAt: DateTime.now(),
      // The author's own upvote, shown at once; the row is written below.
      score: 1,
      myVote: 1,
      mine: true,
    );

    final override = debugPostOverride;
    if (override != null) {
      await override(created);
    } else {
      final client = _client;
      if (client == null) throw PublicForumError('No server configured.');
      try {
        await client.from('public_forum_posts').insert({
          'id': created.id,
          'author_phone': AccountService.e164(phone),
          'author_username': created.authorUsername,
          'author_name': created.authorName,
          'author_verified': created.authorVerified,
          'title': created.title,
          'body': created.body,
          'tag': created.tag,
          if (created.section.isNotEmpty) 'section': created.section,
          if (created.gifUrl.isNotEmpty) 'gif_url': created.gifUrl,
          if (imagePath.isNotEmpty) 'image_path': imagePath,
        });
        // Reddit-style author auto-upvote, so a fresh post reads as +1.
        await client.from('public_forum_votes').insert({
          'post_id': created.id,
          'voter_phone': AccountService.e164(phone),
          'dir': 1,
        });
      } catch (e) {
        throw PublicForumError(_explain(e));
      }
    }
    _posts = [created, ..._posts];
    ScoreStore.instance
      ..award(ScoreStore.pointsPerFeedPost, source: 'forum')
      ..recordFlag('forum_post');
    notifyListeners();
    return created;
  }

  /// Sets this account's vote on [postId] to [dir] (-1, 0 or 1). 0 removes it.
  /// Optimistic: the score and the arrow move at once and roll back on error.
  Future<void> vote(String postId, int dir) async {
    if (local.Session.instance.isNumberless) {
      throw PublicForumError('Voting needs a phone number.');
    }
    // A phone account whose Supabase session has lapsed is a DIFFERENT state
    // from a name-only one, and it used to be indistinguishable: the write
    // went out as `anon`, Postgres answered "permission denied" (the grants
    // are `to authenticated`), and that surfaced as "Couldn't reach the
    // forum. Try again." Caught here, nothing is sent and the sentence is
    // the one thing that helps.
    if (signedOutOfServer) throw PublicForumError(_signedOut);
    final i = _posts.indexWhere((p) => p.id == postId);
    if (i < 0) return;
    final was = _posts[i];
    final prev = was.myVote;
    if (prev == dir) return;
    _posts[i] = was.copyWith(myVote: dir, score: was.score - prev + dir);
    notifyListeners();
    try {
      final override = debugVoteOverride;
      if (override != null) {
        await override(postId, dir);
      } else {
        final client = _client;
        if (client == null) throw PublicForumError('No server configured.');
        final me = AppState.profile.value;
        final phone = local.Session.instance.user.value?.phone ?? me.phone;
        final digits = AccountService.e164(phone);
        if (dir == 0) {
          await client
              .from('public_forum_votes')
              .delete()
              .eq('post_id', postId)
              .eq('voter_phone', digits);
        } else {
          await client.from('public_forum_votes').upsert({
            'post_id': postId,
            'voter_phone': digits,
            'dir': dir,
          });
        }
      }
    } catch (e) {
      // Roll back the optimistic change.
      final j = _posts.indexWhere((p) => p.id == postId);
      if (j >= 0) {
        _posts[j] = _posts[j].copyWith(myVote: prev, score: was.score);
      }
      notifyListeners();
      throw PublicForumError(_explain(e));
    }
  }

  /// Up/down-votes a COMMENT. Returns nothing; the screen holds the comment
  /// list and applies its own optimistic change, the same division the post
  /// list already uses.
  ///
  /// [dir] is 1, -1, or 0 to take a vote back.
  Future<void> voteComment(String commentId, int dir) async {
    if (local.Session.instance.isNumberless) {
      throw PublicForumError('Voting needs a phone number.');
    }
    // A phone account whose Supabase session has lapsed is a DIFFERENT state
    // from a name-only one, and it used to be indistinguishable: the write
    // went out as `anon`, Postgres answered "permission denied" (the grants
    // are `to authenticated`), and that surfaced as "Couldn't reach the
    // forum. Try again." Caught here, nothing is sent and the sentence is
    // the one thing that helps.
    if (signedOutOfServer) throw PublicForumError(_signedOut);
    final override = debugCommentVoteOverride;
    if (override != null) return override(commentId, dir);
    final client = _client;
    if (client == null) throw PublicForumError('No server configured.');
    final me = AppState.profile.value;
    final phone = local.Session.instance.user.value?.phone ?? me.phone;
    final digits = AccountService.e164(phone);
    try {
      if (dir == 0) {
        await client
            .from('public_forum_comment_votes')
            .delete()
            .eq('comment_id', commentId)
            .eq('voter_phone', digits);
      } else {
        await client.from('public_forum_comment_votes').upsert({
          'comment_id': commentId,
          'voter_phone': digits,
          'dir': dir,
        });
      }
    } catch (e) {
      throw PublicForumError(_explain(e));
    }
  }

  /// Loads a post's comments, newest first.
  Future<List<PublicForumComment>> commentsOf(String postId) async {
    final override = debugCommentsOverride;
    if (override != null) return override(postId);
    final client = _client;
    if (client == null) return const [];
    // The score lives on a VIEW added by the comment-votes migration; the
    // table itself has no such column. Ask for the view, and fall back to the
    // plain table when the migration has not been run — a forum with no
    // comment scores is the old behaviour, whereas a hard failure here is no
    // comments at all.
    const cols = 'id, post_id, author_username, author_name, author_verified, '
        'body, gif_url, parent_id, created_at';
    try {
      List<dynamic> rows;
      try {
        rows = await client
            .from('public_forum_comments_v')
            .select('$cols, score')
            .eq('post_id', postId)
            .order('created_at', ascending: true)
            .limit(500);
      } catch (_) {
        rows = await client
            .from('public_forum_comments')
            .select(cols)
            .eq('post_id', postId)
            .order('created_at', ascending: true)
            .limit(500);
      }
      final mine = AppState.profile.value.username;
      return [
        for (final r in rows)
          () {
            final c =
                PublicForumComment.fromRow(Map<String, dynamic>.from(r as Map));
            return mine.isNotEmpty && c.authorUsername == mine
                ? PublicForumComment(
                    id: c.id,
                    postId: c.postId,
                    authorUsername: c.authorUsername,
                    authorName: c.authorName,
                    authorVerified: c.authorVerified,
                    body: c.body,
                    gifUrl: c.gifUrl,
                    parentId: c.parentId,
                    createdAt: c.createdAt,
                    mine: true)
                : c;
          }(),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Adds a comment. Requires a session; screened like a post.
  Future<PublicForumComment> comment(
    String postId,
    String body, {
    String? parentId,
    String? gifUrl,
  }) async {
    final text = body.trim();
    if (text.isEmpty && (gifUrl ?? '').isEmpty) {
      throw PublicForumError('Write something first.');
    }
    if (text.length > maxBody) {
      throw PublicForumError('Keep the comment under $maxBody characters.');
    }
    final me = AppState.profile.value;
    final phone = local.Session.instance.user.value?.phone ?? me.phone;
    if (phone.trim().isEmpty) throw PublicForumError('Sign in to comment.');
    if (local.Session.instance.isNumberless) {
      throw PublicForumError('Commenting needs a phone number.');
    }
    // A phone account whose Supabase session has lapsed is a DIFFERENT state
    // from a name-only one, and it used to be indistinguishable: the write
    // went out as `anon`, Postgres answered "permission denied" (the grants
    // are `to authenticated`), and that surfaced as "Couldn't reach the
    // forum. Try again." Caught here, nothing is sent and the sentence is
    // the one thing that helps.
    if (signedOutOfServer) throw PublicForumError(_signedOut);
    if (text.isNotEmpty) {
      final blocked = await PublicFeedStore.instance.screen(text);
      if (blocked != null) throw PublicForumError(blocked);
    }
    final c = PublicForumComment(
      id: _commentId(),
      postId: postId,
      authorUsername: me.username,
      authorName: me.name,
      authorVerified: me.verified,
      body: text,
      gifUrl: gifUrl ?? '',
      parentId: parentId,
      createdAt: DateTime.now(),
      mine: true,
    );
    final override = debugCommentOverride;
    if (override != null) {
      await override(postId, c);
    } else {
      final client = _client;
      if (client == null) throw PublicForumError('No server configured.');
      try {
        await client.from('public_forum_comments').insert({
          'id': c.id,
          'post_id': postId,
          'author_phone': AccountService.e164(phone),
          'author_username': c.authorUsername,
          'author_name': c.authorName,
          'author_verified': c.authorVerified,
          'body': c.body,
          if (c.gifUrl.isNotEmpty) 'gif_url': c.gifUrl,
          if (parentId != null) 'parent_id': parentId,
        });
      } catch (e) {
        throw PublicForumError(_explain(e));
      }
    }
    // Bump the visible comment count on the post.
    final i = _posts.indexWhere((p) => p.id == postId);
    if (i >= 0) {
      _posts[i] = _posts[i].copyWith(commentCount: _posts[i].commentCount + 1);
      notifyListeners();
    }
    return c;
  }
}
