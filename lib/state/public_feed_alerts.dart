import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/feed_notification.dart';
import '../app_state.dart';
import 'feed_store.dart';
import 'public_feed_store.dart';

/// Tells you when somebody likes, replies to or reposts one of your PUBLIC
/// posts — the one feed in the app that could never say so.
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
/// which starts at zero anyway.
///
/// On the device and nowhere else: what is stored is a handful of integers
/// about your own posts, and it is account-scoped (wired into
/// `account_wipe.dart`) because the next account's counters are not this
/// one's.
class PublicFeedAlerts {
  PublicFeedAlerts._();
  static final PublicFeedAlerts instance = PublicFeedAlerts._();

  static const String _key = 'public_feed_alert_counts';

  /// How many posts may be looked up in detail in one scan. A rise is found
  /// for free by the list query; naming who is behind it costs a round trip
  /// each, and a busy account should not spend twenty of them on a resume.
  /// Rises past the cap are BASELINED rather than held over — see [scan].
  static const int maxLookupsPerScan = 4;

  /// The most people named for one post in one scan. Twelve likes overnight
  /// is worth knowing about; twelve rows in the Notifications tab, all
  /// saying the same thing about the same post, is not.
  static const int maxNamedPerPost = 5;

  /// postId -> [likes, replies, reposts] as of the last scan.
  final Map<String, List<int>> _seen = {};
  SharedPreferences? _prefs;
  bool _loaded = false;
  bool _scanning = false;

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    _seen.clear();
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
  Future<void> scan() async {
    if (_scanning) return;
    final me = AppState.profile.value.username.trim();
    // No handle, no posts to have been liked: a name-only account cannot post
    // publicly at all, and an account that has not claimed a username has
    // nothing the query could match.
    if (me.isEmpty) return;
    _scanning = true;
    try {
      if (!_loaded) await load();
      final store = PublicFeedStore.instance;
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
  void resetForTest() {
    _seen.clear();
    _prefs = null;
    _loaded = false;
    _scanning = false;
  }
}
