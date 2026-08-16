import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/feed_notification.dart';
import '../app_state.dart';
import 'feed_store.dart';
import 'public_feed_store.dart';
import 'public_forum_store.dart';

/// Tells you when somebody likes, replies to or reposts one of your PUBLIC
/// posts, comments on your FORUM posts, follows you, or @mentions you — the
/// public surfaces, which could never say any of it.
///
/// **Why this has to be a scan at all.** Every other interaction in the app
/// arrives: a server feed's like is a relay event addressed to the members of
/// that server, a channel mention rides the community bus, a chat reaction
/// comes over the pairwise ratchet. The public timeline has none of that. It
/// is a world-readable table with no per-user delivery, so when a stranger
/// likes your post NOTHING is sent to your device — the row's counter just
/// goes up on a server you are not subscribed to. `public_feed_screen.dart`
/// has said so since mentions shipped ("a feed-post mention does not PING the
/// tagged person… a scan-on-load notifier would be a separate follow-up").
/// This is that follow-up, and it is deliberately the cheap half of it: the
/// honest alternative is a server-side trigger calling `push-send`, which
/// needs a phone to address and a public post only names a handle.
///
/// **The shape: counts say THAT, one lookup says WHO.** A single query for
/// your own posts already carries `likeCount`/`replyCount`/`repostCount`, so
/// one round trip finds every post that has been interacted with since the
/// last scan. Only those posts then cost a second query to name the people —
/// at most [maxLookupsPerScan] of them, newest first.
///
/// **A post seen for the first time is a BASELINE, never an alert.** That is
/// what stops the first scan after an update from raising a notification for
/// every like the account has ever collected. It costs nothing on a new post,
/// which starts at zero anyway. The follower count follows the same rule.
///
/// **Three round trips on a quiet scan** — your newsfeed posts, your follower
/// count, and your forum posts. Mentions are free (a pass over the timeline
/// already in memory), and every who-was-it lookup only happens when a number
/// actually moved.
///
/// On the device and nowhere else: what is stored is a handful of integers
/// about your own posts, and it is account-scoped (wired into
/// `account_wipe.dart`) because the next account's counters are not this
/// one's.
class PublicFeedAlerts {
  PublicFeedAlerts._();
  static final PublicFeedAlerts instance = PublicFeedAlerts._();

  static const String _key = 'public_feed_alert_counts';
  static const String _followerKey = 'public_feed_alert_followers';
  static const String _mentionKey = 'public_feed_alert_mentions';
  static const String _forumKey = 'public_feed_alert_forum';

  /// How many posts may be looked up in detail in one scan. A rise is found
  /// for free by the list query; naming who is behind it costs a round trip
  /// each, and a busy account should not spend twenty of them on a resume.
  /// Rises past the cap are BASELINED rather than held over — see [scan].
  static const int maxLookupsPerScan = 4;

  /// How many mention ids are carried forward. A ceiling on a set that
  /// would otherwise grow for the life of the account; dropping the oldest
  /// can at worst re-announce a mention nobody has scrolled to in a very
  /// long time.
  static const int maxRememberedMentions = 300;

  /// The least time between two scans that were not asked for by hand.
  ///
  /// iOS resumes an app constantly — switching away and back, a notification
  /// pulled down and dismissed — and each scan is three round trips. Without
  /// this, flicking between two apps would fire them over and over for an
  /// answer that cannot have changed. A pull-to-refresh passes `force`,
  /// because somebody who asks by hand has asked.
  static const Duration minScanInterval = Duration(minutes: 2);

  /// The most people named for one post in one scan. Twelve likes overnight
  /// is worth knowing about; twelve rows in the Notifications tab, all
  /// saying the same thing about the same post, is not.
  static const int maxNamedPerPost = 5;

  /// postId -> [likes, replies, reposts] as of the last scan.
  final Map<String, List<int>> _seen = {};

  /// How many followers the server reported last time. Null means never
  /// asked — the same baseline rule the posts follow, and the reason a fresh
  /// install is not told about every follower the account already had.
  int? _followers;

  /// Post ids already known to mention you. Null means never looked, which
  /// is what makes the first scan a baseline rather than an announcement.
  Set<String>? _mentioned;

  /// forumPostId -> comment count as of the last scan. Same baseline rule.
  final Map<String, int> _forum = {};

  SharedPreferences? _prefs;
  bool _loaded = false;
  bool _scanning = false;

  /// When the last scan ran. In memory only: a fresh launch SHOULD scan, and
  /// persisting this would make a cold start skip the one moment somebody is
  /// most likely to be looking for what they missed.
  DateTime? _lastScan;

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    _seen.clear();
    _followers = _prefs!.getInt(_followerKey);
    // Null (never written) is what makes the first scan a baseline, so the
    // absent case has to survive the read rather than becoming an empty set.
    _mentioned = _prefs!.getStringList(_mentionKey)?.toSet();
    _forum.clear();
    final rawForum = _prefs!.getString(_forumKey) ?? '';
    if (rawForum.isNotEmpty) {
      try {
        for (final e in (jsonDecode(rawForum) as Map).entries) {
          _forum['${e.key}'] = (e.value as num).toInt();
        }
      } catch (_) {}
    }
    final raw = _prefs!.getString(_key) ?? '';
    if (raw.isNotEmpty) {
      try {
        for (final e in (jsonDecode(raw) as Map).entries) {
          final counts = [
            for (final n in (e.value as List)) (n as num).toInt(),
          ];
          if (counts.length == 3) _seen['${e.key}'] = counts;
        }
      } catch (_) {}
    }
    _loaded = true;
  }

  Future<void> _save() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(_seen));
  }

  /// Looks for interactions with your own public posts and files one
  /// notification per person, through the same list and the same tab the
  /// server feed's alerts already use.
  ///
  /// Silent about its own failures on purpose: an unreachable server means
  /// no alerts this time, not an error in front of somebody who did not ask
  /// for anything.
  ///
  /// [force] skips the [minScanInterval] throttle — for a pull-to-refresh,
  /// where the gesture IS the request. [now] is a test seam.
  Future<void> scan({bool force = false, DateTime? now}) async {
    if (_scanning) return;
    final at = now ?? DateTime.now();
    final last = _lastScan;
    if (!force && last != null && at.difference(last) < minScanInterval) {
      return;
    }
    final me = AppState.profile.value.username.trim();
    // No handle, no posts to have been liked: a name-only account cannot post
    // publicly at all, and an account that has not claimed a username has
    // nothing the query could match.
    if (me.isEmpty) return;
    _scanning = true;
    // Stamped before the work, not after: a scan that throws half way
    // through must not leave the throttle open to a retry storm.
    _lastScan = at;
    try {
      if (!_loaded) await load();
      final store = PublicFeedStore.instance;
      // Independent of the posts, and deliberately first: an account with
      // nothing posted still gains followers, and the early return below
      // would have skipped them.
      await _scanFollowers(store, me);
      await _mentionsIn(store.posts, me);
      await _scanForum(me);
      final mine = await store.postsBy(me);
      if (mine.isEmpty) return;

      // Newest first, which is the order postsBy answers in — so when the cap
      // bites, it is the oldest post's likes that go unnamed.
      final risen = <(String, int, int)>[]; // (postId, which, delta)
      final fresh = <String, List<int>>{};
      for (final p in mine) {
        final now = [p.likeCount, p.replyCount, p.repostCount];
        fresh[p.id] = now;
        final before = _seen[p.id];
        if (before == null) continue; // first sight: baseline, never an alert
        for (var which = 0; which < 3; which++) {
          if (now[which] > before[which]) {
            risen.add((p.id, which, now[which] - before[which]));
          }
        }
      }

      // The new baseline is written for EVERY post in the window, including
      // the rises this scan will not have room to name. Holding those over
      // instead would starve them anyway — the cap always picks the same
      // newest few — and would keep re-querying them for as long as the
      // account lived. A bound that quietly never bounds is worse than one
      // that says what it drops.
      _seen
        ..clear()
        ..addAll(fresh);
      await _save();

      for (final (postId, which, delta) in risen.take(maxLookupsPerScan)) {
        switch (which) {
          case 0:
            await _nameLikers(store, postId, delta, me);
          case 1:
            await _nameRepliers(store, postId, delta, me);
          case 2:
            await _nameReposters(store, postId, delta, me);
        }
      }
    } catch (_) {
      // Offline, or a server that answered with something unexpected.
    } finally {
      _scanning = false;
    }
  }

  /// "X followed you" — the one notification every social app has and this
  /// one had none of.
  ///
  /// Same shape as the likes, for the same reason: a follow edge carries no
  /// id, so the COUNT says how many are new and `followersOf` — newest
  /// first — says who. The count is the cheap half and is asked every scan;
  /// the list costs a second round trip and is asked only when the number
  /// actually moved.
  Future<void> _scanFollowers(PublicFeedStore store, String me) async {
    final counts = await store.followCounts(me);
    if (counts == null) return; // unavailable is not "nobody follows you"
    final now = counts.$1;
    final before = _followers;
    if (before != now) {
      _followers = now;
      final prefs = _prefs ??= await SharedPreferences.getInstance();
      await prefs.setInt(_followerKey, now);
    }
    // First sight is a baseline, and a drop is somebody unfollowing — which
    // is not an event this app tells anybody about.
    if (before == null || now <= before) return;
    final list = await store.followersOf(me);
    if (list == null) return;
    var named = 0;
    final delta = now - before;
    for (final (username, name) in list) {
      if (named >= delta || named >= maxNamedPerPost) break;
      if (username.isEmpty) continue;
      if (username.toLowerCase() == me.toLowerCase()) continue;
      named++;
      FeedStore.instance.notePublicInteraction(
        // Keyed by the person, so a follow, an unfollow and a re-follow
        // raise one notification rather than a stream of them. The cost is
        // that a genuine re-follow much later is silent.
        id: 'pubfollow_$username',
        type: FeedNotificationType.follow,
        actorName: name.isEmpty ? '@$username' : name,
        actorUsername: username,
        // A follow is about a person; there is no post to open.
        postId: '',
        time: DateTime.now(),
      );
    }
  }

  /// @mentions of you in OTHER people's public posts.
  ///
  /// **Only what the timeline has already loaded**, and that limit is real:
  /// there is no server-side search for your handle to call, so a mention in
  /// a post this device never loads is never seen. It costs NOTHING — no
  /// query, no round trip, just a pass over posts already in memory — which
  /// is what makes a partial answer worth having rather than a reason to
  /// keep offering none at all. The server feed has notified on mentions
  /// since it shipped; this is the public timeline catching up as far as it
  /// honestly can.
  /// **First sight is a baseline here too**, and it has to be: unlike a like,
  /// a mention has no counter to compare against, so without one the first
  /// scan after an update would announce every mention already sitting in the
  /// loaded timeline — the exact flood the post baseline exists to prevent.
  /// The seen set is remembered by post id rather than by a clock, so it
  /// cannot be confused by a device whose time is wrong.
  Future<void> _mentionsIn(List<PublicPost> posts, String me) async {
    final myName = AppState.profile.value.name;
    final found = <String>{};
    final fresh = <PublicPost>[];
    for (final p in posts) {
      if (p.authorUsername.isEmpty) continue;
      if (p.authorUsername.toLowerCase() == me.toLowerCase()) continue;
      if (p.body.isEmpty) continue;
      if (!FeedStore.mentionsMe(p.body, myName: myName, myUsername: me)) {
        continue;
      }
      found.add(p.id);
      if (_mentioned != null && !_mentioned!.contains(p.id)) fresh.add(p);
    }
    // Remembered even when nothing is announced — that IS the baseline on
    // the first scan — and capped, oldest dropped, so a long-lived account
    // does not carry an unbounded list of ids for a feature this small.
    final seen = _mentioned ??= <String>{};
    seen.addAll(found);
    if (seen.length > maxRememberedMentions) {
      _mentioned = seen.skip(seen.length - maxRememberedMentions).toSet();
    }
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    await prefs.setStringList(_mentionKey, _mentioned!.toList());

    for (final p in fresh.take(maxNamedPerPost)) {
      FeedStore.instance.notePublicInteraction(
        // The post's own id: a mention IS a post, so the dedupe is exact.
        id: 'pubmention_${p.id}',
        type: FeedNotificationType.mention,
        actorName: p.authorName.isEmpty ? '@${p.authorUsername}' : p.authorName,
        actorUsername: p.authorUsername,
        postId: p.id,
        time: p.createdAt,
        preview: p.body,
      );
    }
  }


  /// Comments on your own PUBLIC FORUM posts.
  ///
  /// The forum is a whole surface that raised nothing at all — its own
  /// tables, its own board, and no delivery of any kind, exactly like the
  /// newsfeed. Same shape as the rest of this file: the comment COUNT on
  /// your own posts says that something happened, and `commentsOf` says who.
  ///
  /// **Votes are deliberately not covered.** `public_forum_votes` scopes its
  /// read policy to your own row, so a device cannot learn WHO upvoted
  /// anything — by design, and the right design. An alert with nobody behind
  /// it is the thing this file refuses for likes, so a score that moved is
  /// left to speak for itself on the post.
  Future<void> _scanForum(String me) async {
    final store = PublicForumStore.instance;
    final mine = await store.postsBy(me);
    if (mine.isEmpty) return;
    final risen = <(String, int)>[];
    final fresh = <String, int>{};
    for (final p in mine) {
      fresh[p.id] = p.commentCount;
      final before = _forum[p.id];
      if (before == null) continue; // first sight is a baseline
      if (p.commentCount > before) {
        risen.add((p.id, p.commentCount - before));
      }
    }
    _forum
      ..clear()
      ..addAll(fresh);
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    await prefs.setString(_forumKey, jsonEncode(_forum));

    for (final (postId, delta) in risen.take(maxLookupsPerScan)) {
      final comments = await store.commentsOf(postId);
      if (comments.isEmpty) continue;
      // Oldest first, like the newsfeed's replies, so the new ones are at
      // the end.
      final take = delta > maxNamedPerPost ? maxNamedPerPost : delta;
      final from = comments.length - take;
      for (final c in comments.sublist(from < 0 ? 0 : from)) {
        if (c.authorUsername.toLowerCase() == me.toLowerCase()) continue;
        FeedStore.instance.notePublicInteraction(
          // A comment is a row with its own id, so the dedupe is exact.
          id: c.id,
          type: FeedNotificationType.reply,
          actorName:
              c.authorName.isEmpty ? '@${c.authorUsername}' : c.authorName,
          actorUsername: c.authorUsername,
          // The POST, not the comment: the forum opens a thread, and a
          // comment has no screen of its own to land on.
          postId: postId,
          time: c.createdAt,
          preview: c.body,
          source: FeedNotificationSource.publicForum,
        );
      }
    }
  }

  /// Likes are the awkward one: a like has no id of its own anywhere in the
  /// schema, so there is nothing to dedupe on and nothing to ask "which of
  /// these is new". What there is instead is [PublicFeedStore.likersOf],
  /// which answers NEWEST FIRST — so the first [delta] of it are the people
  /// behind the rise.
  ///
  /// That is exact while likes only accumulate, and degrades in one
  /// direction only: if somebody unliked between scans, the count moved less
  /// than the number of new likers and the oldest of them go unnamed. It can
  /// never name somebody who has not liked the post, which is the failure
  /// worth avoiding — "Ada liked your post" about somebody who did not is a
  /// far worse thing to show than a like that passed quietly.
  Future<void> _nameLikers(
      PublicFeedStore store, String postId, int delta, String me) async {
    final likers = await store.likersOf(postId);
    // Null is "the answer is unavailable", which is not "nobody liked it".
    if (likers == null) return;
    var named = 0;
    for (final (username, name) in likers) {
      if (named >= delta || named >= maxNamedPerPost) break;
      if (username.isEmpty) continue;
      if (username.toLowerCase() == me.toLowerCase()) continue;
      named++;
      FeedStore.instance.notePublicInteraction(
        // No like id exists, so the pair IS the identity — and it makes the
        // dedupe in notePublicInteraction do real work when a scan overlaps
        // with one that already named this person.
        id: 'publike_${postId}_$username',
        type: FeedNotificationType.like,
        actorName: name.isEmpty ? '@$username' : name,
        actorUsername: username,
        postId: postId,
        time: DateTime.now(),
      );
    }
  }

  /// A reply is a post, so unlike a like it has a real id to dedupe on and a
  /// real time of its own. Replies come back oldest first, so the new ones
  /// are at the END.
  Future<void> _nameRepliers(
      PublicFeedStore store, String postId, int delta, String me) async {
    final thread = await store.fetchThread(postId);
    final replies = thread?.replies ?? const <PublicPost>[];
    if (replies.isEmpty) return;
    final take = delta > maxNamedPerPost ? maxNamedPerPost : delta;
    final from = replies.length - take;
    for (final r in replies.sublist(from < 0 ? 0 : from)) {
      if (r.authorUsername.toLowerCase() == me.toLowerCase()) continue;
      FeedStore.instance.notePublicInteraction(
        id: r.id,
        type: FeedNotificationType.reply,
        actorName:
            r.authorName.isEmpty ? '@${r.authorUsername}' : r.authorName,
        actorUsername: r.authorUsername,
        // Opens the reply itself, not your own post — the thread reads from
        // there and it is what somebody tapping "replied to you" is after.
        postId: r.id,
        time: r.createdAt,
        preview: r.body,
      );
    }
  }

  /// A repost is also a post of its own, newest first.
  Future<void> _nameReposters(
      PublicFeedStore store, String postId, int delta, String me) async {
    final reposts = await store.repostersOf(postId);
    var named = 0;
    for (final r in reposts) {
      if (named >= delta || named >= maxNamedPerPost) break;
      if (r.authorUsername.toLowerCase() == me.toLowerCase()) continue;
      named++;
      FeedStore.instance.notePublicInteraction(
        id: r.id,
        type: FeedNotificationType.repost,
        actorName:
            r.authorName.isEmpty ? '@${r.authorUsername}' : r.authorName,
        actorUsername: r.authorUsername,
        // Your own post: a plain repost has nothing of its own to read.
        postId: postId,
        time: r.createdAt,
        preview: r.body,
      );
    }
  }

  @visibleForTesting
  Map<String, List<int>> get debugSeen =>
      {for (final e in _seen.entries) e.key: List.unmodifiable(e.value)};

  @visibleForTesting
  Map<String, int> get debugForumSeen => Map.unmodifiable(_forum);

  @visibleForTesting
  int? get debugFollowerBaseline => _followers;

  @visibleForTesting
  Set<String>? get debugMentioned =>
      _mentioned == null ? null : Set.unmodifiable(_mentioned!);

  @visibleForTesting
  void resetForTest() {
    _lastScan = null;
    _seen.clear();
    _forum.clear();
    _followers = null;
    _mentioned = null;
    _prefs = null;
    _loaded = false;
    _scanning = false;
  }
}
