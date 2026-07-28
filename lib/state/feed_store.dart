import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_state.dart';
import '../models/feed_notification.dart';
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

  /// An animated GIF attached to the post, by URL. Null for a text post.
  final String? gifUrl;

  /// When set, this entry is a repost: it re-surfaces the post with this id
  /// in the timeline under the reposter's name, X-style.
  final String? repostOfId;

  /// True once the author has rewritten the post, so readers can see the text
  /// changed after people replied to it.
  final bool edited;

  /// Pinned to the top of its server's feed by a moderator.
  final bool pinned;

  /// Poll fields. [pollOptions] empty means this isn't a poll; [pollVotes]
  /// is the tally per option and [pollMyVote] this device's choice (-1 none).
  final String pollQuestion;
  final List<String> pollOptions;
  final List<int> pollVotes;
  final int pollMyVote;

  bool get isPoll => pollOptions.isNotEmpty;
  int get pollTotalVotes => pollVotes.fold(0, (n, v) => n + v);

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
    this.gifUrl,
    this.repostOfId,
    this.edited = false,
    this.pinned = false,
    this.pollQuestion = '',
    this.pollOptions = const [],
    this.pollVotes = const [],
    this.pollMyVote = -1,
  });

  FeedPost copyWith({
    int? likes,
    int? reposts,
    int? replies,
    bool? liked,
    bool? reposted,
    String? text,
    bool? edited,
    bool? pinned,
    List<int>? pollVotes,
    int? pollMyVote,
  }) =>
      FeedPost(
        id: id,
        communityId: communityId,
        authorName: authorName,
        authorUsername: authorUsername,
        time: time,
        text: text ?? this.text,
        likes: likes ?? this.likes,
        reposts: reposts ?? this.reposts,
        replies: replies ?? this.replies,
        liked: liked ?? this.liked,
        reposted: reposted ?? this.reposted,
        parentId: parentId,
        gifUrl: gifUrl,
        repostOfId: repostOfId,
        edited: edited ?? this.edited,
        pinned: pinned ?? this.pinned,
        pollQuestion: pollQuestion,
        pollOptions: pollOptions,
        pollVotes: pollVotes ?? this.pollVotes,
        pollMyVote: pollMyVote ?? this.pollMyVote,
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
        if (gifUrl != null) 'gifUrl': gifUrl,
        if (repostOfId != null) 'repostOfId': repostOfId,
        if (edited) 'edited': true,
        if (pinned) 'pinned': true,
        if (isPoll) ...{
          'pollQuestion': pollQuestion,
          'pollOptions': pollOptions,
          'pollVotes': pollVotes,
          'pollMyVote': pollMyVote,
        },
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
        gifUrl: j['gifUrl'] as String?,
        repostOfId: j['repostOfId'] as String?,
        edited: j['edited'] as bool? ?? false,
        pinned: j['pinned'] as bool? ?? false,
        pollQuestion: j['pollQuestion'] as String? ?? '',
        pollOptions:
            (j['pollOptions'] as List? ?? const []).whereType<String>().toList(),
        pollVotes: (j['pollVotes'] as List? ?? const [])
            .map((v) => (v as num).toInt())
            .toList(),
        pollMyVote: j['pollMyVote'] as int? ?? -1,
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

  // Bookmarks: posts saved on this device.
  final Set<String> _savedIds = {};

  // Tombstones for deleted posts: without them a deleted post resurrects
  // the next time the encrypted cloud blob (uploaded before the delete) or
  // a queued relay copy replays it.
  final Set<String> _deletedIds = {};

  // Interactions with you — replies, @mentions, reposts, likes — newest first.
  final List<FeedNotification> _notifications = [];

  // Which (post, liker) pairs this device has counted, so a replayed like
  // event (mailbox or reconnect) can't inflate the tally.
  final Set<String> _likedBy = {};

  /// Feed interactions with you, newest first.
  List<FeedNotification> get notifications =>
      List.unmodifiable(_notifications);

  /// How many are still unseen (drives the tab badge).
  int get unseenNotificationCount =>
      _notifications.where((n) => !n.seen).length;

  /// Marks every feed notification seen.
  void markNotificationsSeen() {
    if (_notifications.every((n) => n.seen)) return;
    for (var i = 0; i < _notifications.length; i++) {
      _notifications[i] = _notifications[i].copyWith(seen: true);
    }
    _save();
    notifyListeners();
  }

  /// Pure: whether an incoming [post] interacts with [myUsername] (whose own
  /// posts are [myPostIds]), and if so, as what. Returns null for anything
  /// that isn't about you — including your own posts echoing back.
  static FeedNotification? notificationFor(FeedPost post,
      {required String myUsername, required Set<String> myPostIds}) {
    final me = myUsername.toLowerCase();
    // Never notify yourself about your own actions.
    if (post.authorUsername.toLowerCase() == me) return null;

    FeedNotificationType? type;
    var thread = post.id;
    if (post.repostOfId != null && myPostIds.contains(post.repostOfId)) {
      type = FeedNotificationType.repost;
      thread = post.repostOfId!;
    } else if (post.parentId != null && myPostIds.contains(post.parentId)) {
      type = FeedNotificationType.reply;
    } else if (RegExp('@$myUsername\\b', caseSensitive: false)
        .hasMatch(post.text)) {
      type = FeedNotificationType.mention;
    }
    if (type == null || me.isEmpty) return null;
    return FeedNotification(
      id: post.id,
      type: type,
      communityId: post.communityId,
      actorName: post.authorName,
      actorUsername: post.authorUsername,
      time: post.time,
      threadPostId: thread,
      preview: post.text,
    );
  }

  /// Pure: whether [text] @mentions [myName] (matched on the one-word token
  /// form a channel mention uses — "Ada Lovelace" is written "@AdaLovelace"),
  /// or by [myUsername]. Case-insensitive, and only at a word boundary so
  /// "@AdaLovelaceSmith" doesn't ping Ada.
  static bool mentionsMe(String text,
      {required String myName, required String myUsername}) {
    final tokens = <String>{
      myName.replaceAll(RegExp(r'[^\w]'), ''),
      myUsername.replaceAll(RegExp(r'[^\w]'), ''),
    }..removeWhere((t) => t.isEmpty || t.toLowerCase() == 'you');
    for (final t in tokens) {
      if (RegExp('@${RegExp.escape(t)}(?!\\w)', caseSensitive: false)
          .hasMatch(text)) {
        return true;
      }
    }
    return false;
  }

  /// Records that a channel message @mentioned the local user. Deduped by
  /// message id and capped like the feed notifications it sits alongside.
  void noteChannelMention({
    required String messageId,
    required String communityId,
    required String channelId,
    required String channelName,
    required String actorName,
    required String preview,
    required DateTime time,
  }) {
    if (_notifications.any((n) => n.id == messageId)) return;
    _notifications.insert(
      0,
      FeedNotification(
        id: messageId,
        type: FeedNotificationType.channelMention,
        communityId: communityId,
        actorName: actorName,
        actorUsername: '',
        time: time,
        threadPostId: '',
        preview: preview,
        channelId: channelId,
        channelName: channelName,
      ),
    );
    if (_notifications.length > 50) _notifications.removeLast();
    _save();
    notifyListeners();
  }

  /// Posts a poll to a server's feed. Needs a question and at least two
  /// non-empty options; blanks and duplicates are dropped first.
  FeedPost? addPoll(
      String communityId, String question, List<String> options) {
    final q = question.trim();
    final seen = <String>{};
    final opts = [
      for (final o in options)
        if (o.trim().isNotEmpty && seen.add(o.trim().toLowerCase())) o.trim()
    ];
    if (q.isEmpty || opts.length < 2) return null;
    final me = AppState.profile.value;
    final post = FeedPost(
      id: 'poll_${DateTime.now().microsecondsSinceEpoch}_${_nextId++}',
      communityId: communityId,
      authorName: me.name,
      authorUsername: me.username.isEmpty ? 'you' : me.username,
      time: DateTime.now(),
      text: '',
      pollQuestion: q,
      pollOptions: opts,
      pollVotes: List<int>.filled(opts.length, 0),
    );
    _posts.add(post);
    _save();
    notifyListeners();
    if (RelayConfig.isEnabled) RelayService.instance.sendFeedPost(post);
    return post;
  }

  /// Casts (or moves) this device's vote on a feed poll. Voting the same
  /// option twice is a no-op; switching moves the tally rather than adding.
  void votePoll(String postId, int option) {
    final i = _posts.indexWhere((p) => p.id == postId);
    if (i == -1) return;
    final p = _posts[i];
    if (!p.isPoll || option < 0 || option >= p.pollOptions.length) return;
    if (p.pollMyVote == option) return;
    final votes = [...p.pollVotes];
    while (votes.length < p.pollOptions.length) {
      votes.add(0);
    }
    final prev = p.pollMyVote;
    if (prev >= 0 && prev < votes.length && votes[prev] > 0) votes[prev]--;
    votes[option]++;
    _posts[i] = p.copyWith(pollVotes: votes, pollMyVote: option);
    _save();
    notifyListeners();
  }

  /// Reposts [postId] with your own comment on top. Unlike a plain repost this
  /// is a real post of its own — you can quote the same thing twice with
  /// different words — so it gets a fresh id rather than the deterministic
  /// repost slot, and it doesn't toggle.
  FeedPost? quoteRepost(String postId, String comment) {
    final text = comment.trim();
    if (text.isEmpty) return null;
    final p = postById(postId);
    if (p == null) return null;
    // Quoting someone's repost quotes the original, like every other client.
    final target = p.repostOfId == null ? p : postById(p.repostOfId!) ?? p;
    final me = AppState.profile.value;
    final entry = FeedPost(
      id: 'q${_nextId++}_${DateTime.now().microsecondsSinceEpoch}',
      communityId: target.communityId,
      authorName: me.name,
      authorUsername: me.username.isEmpty ? 'you' : me.username,
      time: DateTime.now(),
      text: text,
      repostOfId: target.id,
    );
    _posts.add(entry);
    final ti = _posts.indexWhere((x) => x.id == target.id);
    if (ti >= 0) {
      _posts[ti] = _posts[ti].copyWith(reposts: _posts[ti].reposts + 1);
    }
    if (RelayConfig.isEnabled) RelayService.instance.sendFeedPost(entry);
    _save();
    notifyListeners();
    return entry;
  }

  /// Whether [post] is a quote — a repost carrying its own commentary — as
  /// opposed to a plain "reposted" entry.
  static bool isQuote(FeedPost post) =>
      post.repostOfId != null && post.text.trim().isNotEmpty;

  /// Pins/unpins a post to the top of its server's feed. Moderator action —
  /// the caller checks permission. Returns true when now pinned.
  bool togglePinned(String postId) {
    final i = _posts.indexWhere((p) => p.id == postId);
    if (i == -1) return false;
    final nowPinned = !_posts[i].pinned;
    // One pinned post per server, like a pinned tweet — pinning a second
    // replaces the first rather than stacking banners.
    if (nowPinned) {
      final community = _posts[i].communityId;
      for (var j = 0; j < _posts.length; j++) {
        if (_posts[j].pinned && _posts[j].communityId == community) {
          _posts[j] = _posts[j].copyWith(pinned: false);
        }
      }
    }
    _posts[i] = _posts[i].copyWith(pinned: nowPinned);
    _save();
    notifyListeners();
    return nowPinned;
  }

  /// Rewrites one of the local user's own posts, flagging it edited. Ignores
  /// empty text, unchanged text, and anyone else's posts.
  bool editPost(String postId, String newText) {
    final text = newText.trim();
    if (text.isEmpty) return false;
    final i = _posts.indexWhere((p) => p.id == postId);
    if (i == -1) return false;
    final post = _posts[i];
    final me = AppState.profile.value.username;
    final mine = post.authorUsername == 'you' ||
        (me.isNotEmpty && post.authorUsername == me);
    if (!mine || post.text == text) return false;
    _posts[i] = post.copyWith(text: text, edited: true);
    _save();
    notifyListeners();
    return true;
  }

  /// Case-insensitive search over a server's posts — matches body text, the
  /// author's display name, and their username (so "@grace" finds her posts).
  /// Pure enough to test.
  static List<FeedPost> searchPosts(List<FeedPost> all, String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return all;
    // A leading "@" reads as "posts by this person", not literal text.
    final byAuthor = q.startsWith('@') ? q.substring(1) : null;
    return [
      for (final p in all)
        if (byAuthor != null
            ? p.authorUsername.toLowerCase().contains(byAuthor) ||
                p.authorName.toLowerCase().contains(byAuthor)
            : p.text.toLowerCase().contains(q) ||
                p.authorName.toLowerCase().contains(q) ||
                p.authorUsername.toLowerCase().contains(q))
          p
    ];
  }

  bool isSaved(String postId) => _savedIds.contains(postId);

  /// Saves/unsaves a post for the Saved filter; returns true when now saved.
  bool toggleSaved(String postId) {
    final nowSaved = !_savedIds.remove(postId);
    if (nowSaved) _savedIds.add(postId);
    _save();
    notifyListeners();
    return nowSaved;
  }

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
            // Repost entries carry no text of their own — the activity
            // preview shows originals only.
            p.repostOfId == null &&
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

  /// The display name we know for [username] from their posts, or null.
  String? authorNameFor(String username) {
    final lu = username.toLowerCase();
    for (final p in _posts) {
      if (p.authorUsername.toLowerCase() == lu && p.authorName.isNotEmpty) {
        return p.authorName;
      }
    }
    return null;
  }

  /// Every username that has posted in [communityId] — mention suggestions.
  List<String> usernamesFor(String communityId) {
    final seen = <String>{};
    final out = <String>[];
    for (final p in _posts) {
      if (p.communityId != communityId) continue;
      final u = p.authorUsername;
      if (u.isEmpty || u == 'you' || !seen.add(u.toLowerCase())) continue;
      out.add(u);
    }
    return out;
  }

  /// Posts [text] as the signed-in user. Returns the new post.
  FeedPost add(String communityId, String text,
      {String? parentId, String? gifUrl}) {
    final me = AppState.profile.value;
    final post = FeedPost(
      id: 'post_${DateTime.now().microsecondsSinceEpoch}_${_nextId++}',
      communityId: communityId,
      authorName: me.name,
      authorUsername: me.username.isEmpty ? 'you' : me.username,
      time: DateTime.now(),
      text: text.trim(),
      parentId: parentId,
      gifUrl: gifUrl,
    );
    _posts.add(post);
    _save();
    notifyListeners();
    // Real-time: everyone in the server sees the post, like messages.
    if (RelayConfig.isEnabled) RelayService.instance.sendFeedPost(post);
    return post;
  }

  /// Merges a post that arrived over the relay from another device.
  /// Dedupes by id; incoming replies bump their parent's count and
  /// incoming reposts bump their original's.
  void addRemote(FeedPost post) {
    if (_deletedIds.contains(post.id)) {
      // Deleted content stays deleted. A repost stub is the one exception:
      // its id is deterministic, so re-reposting legitimately reuses it.
      if (post.repostOfId == null) return;
      _deletedIds.remove(post.id);
    }
    if (_posts.any((p) => p.id == post.id)) return;
    _posts.add(post);
    _maybeNotify(post);
    final parentId = post.parentId;
    if (parentId != null) {
      final i = _posts.indexWhere((p) => p.id == parentId);
      if (i >= 0) {
        _posts[i] = _posts[i].copyWith(replies: _posts[i].replies + 1);
      }
    }
    final repostOfId = post.repostOfId;
    if (repostOfId != null) {
      final i = _posts.indexWhere((p) => p.id == repostOfId);
      if (i >= 0) {
        _posts[i] = _posts[i].copyWith(reposts: _posts[i].reposts + 1);
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
    final nowLiked = !p.liked;
    _posts[i] = p.copyWith(
        liked: nowLiked, likes: p.liked ? p.likes - 1 : p.likes + 1);
    _save();
    notifyListeners();
    // Tell the author's server who liked, so their count moves and — if the
    // post is theirs — they get a "liked you" notification.
    if (RelayConfig.isEnabled) {
      final me = AppState.profile.value;
      RelayService.instance.sendFeedLike(
        p.communityId,
        postId,
        liked: nowLiked,
        likerName: me.name,
        likerUsername: me.username.isEmpty ? 'you' : me.username,
      );
    }
  }

  /// Applies a like/unlike that arrived from another member: moves the
  /// counter and, when it's a like of one of your posts, records a
  /// notification. Deduped so a replayed like can't inflate the count.
  void applyRemoteLike(String postId,
      {required bool liked,
      required String likerName,
      required String likerUsername}) {
    final i = _posts.indexWhere((p) => p.id == postId);
    if (i < 0) return;
    final key = 'like_${postId}_$likerUsername';
    final already = _likedBy.contains(key);
    if (liked == already) return; // idempotent
    if (liked) {
      _likedBy.add(key);
    } else {
      _likedBy.remove(key);
    }
    final p = _posts[i];
    _posts[i] = p.copyWith(
        likes: liked ? p.likes + 1 : (p.likes > 0 ? p.likes - 1 : 0));
    if (liked) {
      final me = AppState.profile.value;
      final myUsername = me.username.isEmpty ? 'you' : me.username;
      final mine = p.authorUsername == 'you' ||
          p.authorUsername.toLowerCase() == myUsername.toLowerCase();
      if (mine && likerUsername.toLowerCase() != myUsername.toLowerCase()) {
        final noteId = 'likenote_${postId}_$likerUsername';
        if (!_notifications.any((n) => n.id == noteId)) {
          _notifications.insert(
              0,
              FeedNotification(
                id: noteId,
                type: FeedNotificationType.like,
                communityId: p.communityId,
                actorName: likerName,
                actorUsername: likerUsername,
                time: DateTime.now(),
                threadPostId: postId,
              ));
          if (_notifications.length > 50) _notifications.removeLast();
        }
      }
    }
    _save();
    notifyListeners();
  }

  /// Records a notification if [post] interacts with the local user. Deduped
  /// by id and capped so the list can't grow without bound.
  void _maybeNotify(FeedPost post) {
    final me = AppState.profile.value;
    final myUsername = me.username.isEmpty ? 'you' : me.username;
    final myPostIds = {
      for (final p in _posts)
        if (p.authorUsername == 'you' ||
            p.authorUsername.toLowerCase() == myUsername.toLowerCase())
          p.id
    };
    final note = notificationFor(post,
        myUsername: myUsername, myPostIds: myPostIds);
    if (note == null) return;
    if (_notifications.any((n) => n.id == note.id)) return;
    _notifications.insert(0, note);
    if (_notifications.length > 50) _notifications.removeLast();
  }

  /// The deterministic id of [username]'s repost of [postId] — the same on
  /// every device, so reposts dedupe and un-reposts find their entry.
  static String repostEntryId(String postId, String username) =>
      'rp_${postId}_by_$username';

  /// Repost = a real timeline entry under your name pointing at the
  /// original, shared with the server like any post; un-repost removes it
  /// everywhere. (Not just a counter anymore.)
  void toggleRepost(String postId) {
    final i = _posts.indexWhere((p) => p.id == postId);
    if (i < 0) return;
    final p = _posts[i];
    // Repost the original even when tapped on someone else's repost entry.
    final target = p.repostOfId == null ? p : postById(p.repostOfId!) ?? p;
    final ti = _posts.indexWhere((x) => x.id == target.id);
    final me = AppState.profile.value;
    final myUsername = me.username.isEmpty ? 'you' : me.username;
    final entryId = repostEntryId(target.id, myUsername);
    if (target.reposted) {
      _deletedIds.add(entryId); // a stale blob must not resurrect it
      _posts.removeWhere((x) => x.id == entryId);
      if (ti >= 0) {
        _posts[ti] = target.copyWith(
            reposted: false,
            reposts: target.reposts > 0 ? target.reposts - 1 : 0);
      }
      if (RelayConfig.isEnabled) {
        RelayService.instance.sendFeedDelete(target.communityId, entryId);
      }
    } else {
      _deletedIds.remove(entryId); // re-reposting revives the same slot
      final entry = FeedPost(
        id: entryId,
        communityId: target.communityId,
        authorName: me.name,
        authorUsername: myUsername,
        time: DateTime.now(),
        text: '',
        repostOfId: target.id,
      );
      _posts.add(entry);
      if (ti >= 0) {
        _posts[ti] =
            target.copyWith(reposted: true, reposts: target.reposts + 1);
      }
      if (RelayConfig.isEnabled) RelayService.instance.sendFeedPost(entry);
    }
    _save();
    notifyListeners();
  }

  /// Removes the post and its whole reply thread — here and, for posts of a
  /// sealed server, on every member's device.
  void deletePost(String postId) {
    final post = postById(postId);
    _removeLocally(postId);
    if (post != null && RelayConfig.isEnabled) {
      RelayService.instance.sendFeedDelete(post.communityId, postId);
    }
  }

  /// Applies a deletion that arrived over the relay from another member.
  void removeRemote(String postId) => _removeLocally(postId);

  void _removeLocally(String postId) {
    final removed = postById(postId);
    // Tombstone everything that goes: the post and its cascade, so no
    // stale copy anywhere can bring any of it back.
    for (final p in _posts) {
      if (p.id == postId || p.parentId == postId || p.repostOfId == postId) {
        _deletedIds.add(p.id);
      }
    }
    _deletedIds.add(postId);
    _posts.removeWhere((p) =>
        p.id == postId || p.parentId == postId || p.repostOfId == postId);
    // An un-repost gives the original its counter back.
    final targetId = removed?.repostOfId;
    if (targetId != null) {
      final ti = _posts.indexWhere((x) => x.id == targetId);
      if (ti >= 0 && _posts[ti].reposts > 0) {
        _posts[ti] = _posts[ti].copyWith(reposts: _posts[ti].reposts - 1);
      }
    }
    _save();
    notifyListeners();
  }

  /// Every post as JSON, for the encrypted cloud backup.
  List<Map<String, dynamic>> exportPosts() =>
      [for (final p in _posts) p.toJson()];

  /// Replaces the feed with posts from a decrypted cloud backup. Posts this
  /// device deleted stay deleted, even when the backup predates the delete.
  void hydratePosts(List<dynamic> raw) {
    _posts
      ..clear()
      ..addAll(raw
          .whereType<Map>()
          .map((m) => FeedPost.fromJson(Map<String, dynamic>.from(m)))
          .where((p) => !_deletedIds.contains(p.id)));
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
        _savedIds
          ..clear()
          ..addAll(
              (decoded['saved'] as List? ?? const []).whereType<String>());
        _deletedIds
          ..clear()
          ..addAll(
              (decoded['deleted'] as List? ?? const []).whereType<String>());
        _notifications
          ..clear()
          ..addAll((decoded['notifs'] as List? ?? const [])
              .whereType<Map>()
              .map((m) =>
                  FeedNotification.fromJson(Map<String, dynamic>.from(m))));
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
            'saved': _savedIds.toList(),
            'deleted': _deletedIds.toList(),
            'notifs': [for (final n in _notifications) n.toJson()],
          }));
    } catch (_) {}
  }

  @visibleForTesting
  void resetForTest() {
    _posts.clear();
    _hiddenIds.clear();
    _mutedUsernames.clear();
    _savedIds.clear();
    _deletedIds.clear();
    _notifications.clear();
    _likedBy.clear();
    _nextId = 1;
    notifyListeners();
  }
}

/// The hashtags used across [posts], most-used first, capped at [limit].
/// Case-insensitive; returned in their first-seen casing. Pure.
List<(String, int)> trendingTags(List<FeedPost> posts, {int limit = 6}) {
  final counts = <String, int>{};
  final display = <String, String>{};
  final pattern = RegExp(r'#[A-Za-z0-9_]+');
  for (final p in posts) {
    for (final m in pattern.allMatches(p.text)) {
      final tag = m.group(0)!;
      final key = tag.toLowerCase();
      counts[key] = (counts[key] ?? 0) + 1;
      display.putIfAbsent(key, () => tag);
    }
  }
  final keys = counts.keys.toList()
    ..sort((a, b) {
      final byCount = counts[b]!.compareTo(counts[a]!);
      return byCount != 0 ? byCount : a.compareTo(b);
    });
  return [for (final k in keys.take(limit)) (display[k]!, counts[k]!)];
}

/// Orders a timeline: newest first, or by engagement (likes + reposts,
/// newest breaking ties) when [top]. A pinned post always leads, whichever
/// order is chosen — that's what pinning means. Pure.
List<FeedPost> sortFeed(List<FeedPost> posts, {bool top = false}) {
  final list = [...posts];
  if (top) {
    list.sort((a, b) {
      final byScore =
          (b.likes + b.reposts).compareTo(a.likes + a.reposts);
      return byScore != 0 ? byScore : b.time.compareTo(a.time);
    });
  } else {
    list.sort((a, b) => b.time.compareTo(a.time));
  }
  // Stable partition, so pinning doesn't disturb the order of everything else.
  return [
    ...list.where((p) => p.pinned),
    ...list.where((p) => !p.pinned),
  ];
}

/// Keeps only posts mentioning [tag] (case-insensitive), '' = all. Pure.
List<FeedPost> filterFeedByTag(List<FeedPost> posts, String tag) {
  if (tag.isEmpty) return posts;
  final q = tag.toLowerCase();
  return posts.where((p) => p.text.toLowerCase().contains(q)).toList();
}

/// "2m", "3h", "5d" — X-style compact age for a post.
String feedAge(DateTime time, {DateTime? now}) {
  final d = (now ?? DateTime.now()).difference(time);
  if (d.inMinutes < 1) return 'now';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) return '${d.inHours}h';
  return '${d.inDays}d';
}
