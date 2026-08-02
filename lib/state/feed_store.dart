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

  /// Asking price in cents (null = not a listing, 0 = free).
  final int? priceCents;

  /// Marketplace category (empty for ordinary posts).
  final String listingCategory;

  /// Condition ('New' / 'Like new' / 'Good' / 'Fair' / 'For parts'), or ''
  /// when the seller didn't say. Optional on purpose: a required condition
  /// gets answered with whatever dismisses the field fastest.
  final String listingCondition;

  /// Whether the seller has marked this listing sold.
  final bool listingSold;

  /// Monotonic revision for listing updates. addRemote replaces a listing
  /// only when this is higher, so a mailbox replaying a stale copy can never
  /// roll back a sold flag.
  final int listingRev;

  /// Whether the author carried the blue check when they wrote this.
  ///
  /// Self-asserted over the sealed relay, exactly like [FeedPost.authorName]
  /// and the `fromVerified` flag chat messages already carry — the server
  /// grants the badge, the client attests it on its posts. The same trust
  /// model the rest of the app uses, no stronger and no weaker.
  final bool authorVerified;

  /// Star rating 1-5 when this post is a review of a listing (it then also
  /// carries the listing's id in [parentId]); 0 everywhere else.
  final int rating;

  bool get isReview => rating > 0;

  /// What the listing asked before its last price change (0 = never
  /// changed). Only ever set by updateListing when the price moved, so a
  /// tile can say "was \$40" — the one edit buyers genuinely care about.
  final int prevPriceCents;

  /// Bucket path of this post's sealed video ('' = none). The bytes live in
  /// Storage — see MarketMedia — because a video cannot ride the relay; only
  /// this address rides in the envelope.
  ///
  /// Named for the listings it was built for, and kept that name on purpose:
  /// an ordinary post's video is the same sealed object in the same bucket
  /// under the same server key, so reusing the field means video on a post
  /// inherits the wire format, the persistence and the tombstone cascade
  /// without a second copy of any of it. Read it through [hasVideo].
  final String listingVideo;

  /// Photo-part index (1-based) when this post is one extra photo of a
  /// listing; 0 everywhere else. Each part rides as its OWN post because the
  /// relay caps a payload around a quarter-megabyte and one photo already
  /// budgets most of it — several photos in one envelope would push past the
  /// cap and fail silently. As children of the listing they inherit its
  /// persistence and die with it in the tombstone cascade.
  final int mediaPart;

  bool get isMediaPart => mediaPart > 0;

  /// Whether this post carries a video, listing or not.
  bool get hasVideo => listingVideo.isNotEmpty;

  /// Poll fields. [pollOptions] empty means this isn't a poll; [pollVotes]
  /// is the tally per option and [pollMyVote] this device's choice (-1 none).
  final String pollQuestion;
  final List<String> pollOptions;
  final List<int> pollVotes;
  final int pollMyVote;

  bool get isPoll => pollOptions.isNotEmpty;
  int get pollTotalVotes => pollVotes.fold(0, (n, v) => n + v);

  /// Marketplace fields. A post with a price is a listing: it rides the same
  /// sealed relay, persistence, and delete-tombstones as every other post —
  /// the transport is the part that is hard to get right, and it already
  /// exists — but it is hidden from timelines and shown in the Marketplace.
  /// [priceCents] null means an ordinary post; 0 means "free".
  bool get isListing => priceCents != null;

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
    this.priceCents,
    this.listingCategory = '',
    this.listingCondition = '',
    this.listingSold = false,
    this.listingRev = 0,
    this.authorVerified = false,
    this.rating = 0,
    this.mediaPart = 0,
    this.listingVideo = '',
    this.prevPriceCents = 0,
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
    bool? listingSold,
    int? listingRev,
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
        priceCents: priceCents,
        listingCategory: listingCategory,
        listingCondition: listingCondition,
        listingSold: listingSold ?? this.listingSold,
        listingRev: listingRev ?? this.listingRev,
        authorVerified: authorVerified,
        rating: rating,
        mediaPart: mediaPart,
        listingVideo: listingVideo,
        prevPriceCents: prevPriceCents,
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
        if (isListing) ...{
          'priceCents': priceCents,
          'listingCategory': listingCategory,
          if (listingCondition.isNotEmpty)
            'listingCondition': listingCondition,
          if (listingSold) 'listingSold': true,
          'listingRev': listingRev,
        },
        if (authorVerified) 'authorVerified': true,
        if (rating > 0) 'rating': rating,
        if (mediaPart > 0) 'mediaPart': mediaPart,
        if (listingVideo.isNotEmpty) 'listingVideo': listingVideo,
        if (prevPriceCents > 0) 'prevPriceCents': prevPriceCents,
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
        priceCents: (j['priceCents'] as num?)?.toInt(),
        listingCategory: j['listingCategory'] as String? ?? '',
        listingCondition: j['listingCondition'] as String? ?? '',
        listingSold: j['listingSold'] as bool? ?? false,
        listingRev: (j['listingRev'] as num?)?.toInt() ?? 0,
        authorVerified: j['authorVerified'] as bool? ?? false,
        rating: (j['rating'] as num?)?.toInt() ?? 0,
        mediaPart: (j['mediaPart'] as num?)?.toInt() ?? 0,
        listingVideo: j['listingVideo'] as String? ?? '',
        prevPriceCents: (j['prevPriceCents'] as num?)?.toInt() ?? 0,
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

  // Where each voter currently stands on each poll, so a replayed vote can't
  // double-count and a switch moves the tally instead of adding to it.
  final Map<String, int> _votedBy = {};

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
  /// The vote is broadcast so everyone in the server sees one shared result —
  /// a poll whose tally differs per device is worse than no poll at all.
  void votePoll(String postId, int option) {
    final i = _posts.indexWhere((p) => p.id == postId);
    if (i == -1) return;
    final p = _posts[i];
    if (!p.isPoll || option < 0 || option >= p.pollOptions.length) return;
    if (p.pollMyVote == option) return;
    final prev = p.pollMyVote;
    _applyVote(i, option, prev, myVote: true);
    final me = AppState.profile.value;
    if (RelayConfig.isEnabled) {
      RelayService.instance.sendFeedVote(
        p.communityId,
        postId,
        option: option,
        previous: prev,
        voterUsername: me.username.isEmpty ? 'you' : me.username,
      );
    }
  }

  /// Applies someone else's vote. [previous] is the option they moved off
  /// (-1 for a first vote), so switching moves the tally instead of inflating
  /// it. Deduped per voter so a mailbox replay or reconnect can't double-count.
  void applyRemoteVote(String postId,
      {required int option,
      required int previous,
      required String voterUsername}) {
    final i = _posts.indexWhere((p) => p.id == postId);
    if (i < 0) return;
    final p = _posts[i];
    if (!p.isPoll || option < 0 || option >= p.pollOptions.length) return;
    // One live vote per person: re-sending the same choice changes nothing.
    final key = 'vote_${postId}_$voterUsername';
    if (_votedBy[key] == option) return;
    // Trust our own record of where they were over the sender's claim, so a
    // replayed older event can't subtract from the wrong option.
    final known = _votedBy[key] ?? previous;
    _votedBy[key] = option;
    _applyVote(i, option, known, myVote: false);
  }

  /// Shared tally arithmetic: add to [option], remove from [previous].
  void _applyVote(int i, int option, int previous, {required bool myVote}) {
    final p = _posts[i];
    final votes = [...p.pollVotes];
    while (votes.length < p.pollOptions.length) {
      votes.add(0);
    }
    if (previous >= 0 && previous < votes.length && votes[previous] > 0) {
      votes[previous]--;
    }
    votes[option]++;
    _posts[i] = p.copyWith(
        pollVotes: votes, pollMyVote: myVote ? option : p.pollMyVote);
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
        // Listings live in the Marketplace, not the timeline — a feed full
        // of price tags reads as ads.
        !p.isListing &&
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
            !p.isListing &&
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
      {String? parentId, String? gifUrl, String videoPath = ''}) {
    final me = AppState.profile.value;
    final post = FeedPost(
      id: 'post_${DateTime.now().microsecondsSinceEpoch}_${_nextId++}',
      communityId: communityId,
      authorName: me.name,
      authorUsername: me.username.isEmpty ? 'you' : me.username,
      authorVerified: me.verified,
      time: DateTime.now(),
      text: text.trim(),
      parentId: parentId,
      gifUrl: gifUrl,
      listingVideo: videoPath,
    );
    _posts.add(post);
    _save();
    notifyListeners();
    // Real-time: everyone in the server sees the post, like messages.
    if (RelayConfig.isEnabled) RelayService.instance.sendFeedPost(post);
    return post;
  }

  /// Creates a marketplace listing and shares it with the server, riding the
  /// exact post path — same sealed relay, same persistence, same tombstones.
  FeedPost addListing(
    String communityId, {
    required String title,
    required int priceCents,
    required String category,
    String description = '',
    String? photoUrl,
    List<String> extraPhotos = const [],
    String videoPath = '',
    String condition = '',
  }) {
    final me = AppState.profile.value;
    final post = FeedPost(
      id: 'post_${DateTime.now().microsecondsSinceEpoch}_${_nextId++}',
      communityId: communityId,
      authorName: me.name,
      authorUsername: me.username.isEmpty ? 'you' : me.username,
      authorVerified: me.verified,
      time: DateTime.now(),
      // Title on the first line, details after — a client too old to know
      // about listings shows a readable post instead of stray fields.
      text: description.trim().isEmpty
          ? title.trim()
          : '${title.trim()}\n${description.trim()}',
      gifUrl: photoUrl,
      priceCents: priceCents,
      listingCategory: category,
      listingCondition: condition,
      listingVideo: videoPath,
    );
    _posts.add(post);
    _addPhotoParts(post, extraPhotos);
    _save();
    notifyListeners();
    if (RelayConfig.isEnabled) RelayService.instance.sendFeedPost(post);
    return post;
  }

  /// Extra photos ride as child posts, one broadcast each — see
  /// [FeedPost.mediaPart] for why they cannot share the listing's envelope.
  void _addPhotoParts(FeedPost listing, List<String> photos) {
    var index = 0;
    for (final url in photos) {
      if (url.isEmpty) continue;
      final part = FeedPost(
        id: 'post_${DateTime.now().microsecondsSinceEpoch}_${_nextId++}',
        communityId: listing.communityId,
        authorName: listing.authorName,
        authorUsername: listing.authorUsername,
        time: listing.time,
        text: '',
        parentId: listing.id,
        gifUrl: url,
        mediaPart: ++index,
      );
      _posts.add(part);
      if (RelayConfig.isEnabled) RelayService.instance.sendFeedPost(part);
    }
  }

  /// Every photo of a listing: the cover first, then the parts in order.
  List<String> listingPhotos(String listingId) {
    final i = _posts.indexWhere((p) => p.id == listingId);
    final parts = _posts
        .where((p) =>
            p.parentId == listingId && p.isMediaPart && p.gifUrl != null)
        .toList()
      ..sort((a, b) => a.mediaPart.compareTo(b.mediaPart));
    return [
      if (i != -1 && _posts[i].gifUrl != null) _posts[i].gifUrl!,
      for (final p in parts) p.gifUrl!,
    ];
  }

  /// Listings, newest first — one server's or every server's (null).
  /// Sold listings stay listed (marked) for [soldFor] so a buyer mid-chat
  /// isn't staring at a listing that vanished; older sold ones drop out.
  List<FeedPost> listings({String? communityId, bool includeSold = true}) {
    final list = _posts
        .where((p) =>
            p.isListing &&
            (communityId == null || p.communityId == communityId) &&
            (includeSold || !p.listingSold) &&
            !_hiddenIds.contains(p.id) &&
            !_mutedUsernames.contains(p.authorUsername.toLowerCase()))
        .toList()
      ..sort((a, b) => b.time.compareTo(a.time));
    return list;
  }

  /// Writes (or rewrites) the local user's review of a listing.
  ///
  /// One voice per person: an existing review by this user is deleted first —
  /// which broadcasts its tombstone — and the new one posts in its place, so
  /// editing a review propagates with the machinery replies already have.
  /// Sellers cannot review their own listings; five stars you gave yourself
  /// would make every rating worthless.
  bool addReview(String listingId, {required int rating, String text = ''}) {
    final i = _posts.indexWhere((p) => p.id == listingId);
    if (i == -1 || !_posts[i].isListing) return false;
    final listing = _posts[i];
    final me = AppState.profile.value;
    final myUsername = me.username.isEmpty ? 'you' : me.username;
    final ownListing = listing.authorUsername == 'you' ||
        listing.authorUsername == myUsername ||
        (me.username.isNotEmpty && listing.authorUsername == me.username);
    if (ownListing) return false;
    final clamped = rating.clamp(1, 5);
    final existing = myReviewOf(listingId);
    if (existing != null) deletePost(existing.id);
    final review = FeedPost(
      id: 'post_${DateTime.now().microsecondsSinceEpoch}_${_nextId++}',
      communityId: listing.communityId,
      authorName: me.name,
      authorUsername: myUsername,
      authorVerified: me.verified,
      time: DateTime.now(),
      text: text.trim(),
      parentId: listingId,
      rating: clamped,
    );
    _posts.add(review);
    _save();
    notifyListeners();
    if (RelayConfig.isEnabled) RelayService.instance.sendFeedPost(review);
    return true;
  }

  /// A listing's reviews, newest first.
  List<FeedPost> reviewsFor(String listingId) {
    final list = _posts
        .where((p) =>
            p.parentId == listingId &&
            p.isReview &&
            !_hiddenIds.contains(p.id) &&
            !_mutedUsernames.contains(p.authorUsername.toLowerCase()))
        .toList()
      ..sort((a, b) => b.time.compareTo(a.time));
    return list;
  }

  /// The local user's review of [listingId], or null.
  FeedPost? myReviewOf(String listingId) {
    final me = AppState.profile.value.username;
    for (final p in _posts) {
      if (p.parentId == listingId &&
          p.isReview &&
          (p.authorUsername == 'you' ||
              (me.isNotEmpty && p.authorUsername == me))) {
        return p;
      }
    }
    return null;
  }

  /// A seller's average rating and review count, across every listing of
  /// theirs this device can see. Honest about its horizon: the audience of a
  /// listing is its server's members, and so is the audience of its reviews.
  (double, int) sellerRating(String username) {
    var sum = 0;
    var count = 0;
    for (final l in _posts) {
      if (!l.isListing) continue;
      if (l.authorUsername.toLowerCase() != username.toLowerCase()) continue;
      for (final r in reviewsFor(l.id)) {
        sum += r.rating;
        count++;
      }
    }
    return count == 0 ? (0, 0) : (sum / count, count);
  }

  /// Rewrites one of the local user's own listings — title, price, category,
  /// description, photo — and tells the server. The revision bump is what
  /// lets the update land on other devices: addRemote replaces a listing
  /// only when the incoming revision is higher.
  bool updateListing(
    String postId, {
    required String title,
    required int priceCents,
    required String category,
    String description = '',
    String? photoUrl,
    List<String>? extraPhotos,
    String? videoPath,
    String? condition,
  }) {
    final i = _posts.indexWhere((p) => p.id == postId);
    if (i == -1 || !_posts[i].isListing || title.trim().isEmpty) return false;
    final post = _posts[i];
    final me = AppState.profile.value.username;
    final mine = post.authorUsername == 'you' ||
        (me.isNotEmpty && post.authorUsername == me);
    if (!mine) return false;
    if (extraPhotos != null) {
      // Wholesale replacement, not a diff: the old parts tombstone (which
      // every device honours) and fresh ids post in their place. A diff
      // would save a little bandwidth and buy replay-ordering headaches.
      final oldParts = _posts
          .where((p) => p.parentId == postId && p.isMediaPart)
          .map((p) => p.id)
          .toList();
      for (final id in oldParts) {
        deletePost(id);
      }
    }
    final updated = FeedPost(
      id: post.id,
      communityId: post.communityId,
      authorName: post.authorName,
      authorUsername: post.authorUsername,
      authorVerified: post.authorVerified,
      time: post.time,
      text: description.trim().isEmpty
          ? title.trim()
          : '${title.trim()}\n${description.trim()}',
      gifUrl: photoUrl,
      priceCents: priceCents,
      listingCategory: category,
      listingCondition: condition ?? post.listingCondition,
      listingSold: post.listingSold,
      listingRev: post.listingRev + 1,
      listingVideo: videoPath ?? post.listingVideo,
      // Remember the old ask across ONE change, so a drop can be shown.
      // An unchanged price keeps whatever history it had.
      prevPriceCents: priceCents != (post.priceCents ?? 0)
          ? (post.priceCents ?? 0)
          : post.prevPriceCents,
      edited: true,
    );
    // deletePost above may have shifted indices; find the listing again.
    final j = _posts.indexWhere((p) => p.id == postId);
    _posts[j] = updated;
    if (extraPhotos != null) _addPhotoParts(updated, extraPhotos);
    _save();
    notifyListeners();
    if (RelayConfig.isEnabled) RelayService.instance.sendFeedPost(updated);
    return true;
  }

  /// Flips a listing's sold flag (own listings only) and tells the server.
  bool setListingSold(String postId, bool sold) {
    final i = _posts.indexWhere((p) => p.id == postId);
    if (i == -1 || !_posts[i].isListing) return false;
    final post = _posts[i];
    final me = AppState.profile.value.username;
    final mine = post.authorUsername == 'you' ||
        (me.isNotEmpty && post.authorUsername == me);
    if (!mine || post.listingSold == sold) return false;
    final updated =
        post.copyWith(listingSold: sold, listingRev: post.listingRev + 1);
    _posts[i] = updated;
    _save();
    notifyListeners();
    if (RelayConfig.isEnabled) RelayService.instance.sendFeedPost(updated);
    return true;
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
    // A child of a deleted parent is deleted content too, even under an id
    // the tombstones never saw: the cascade removes the subtree that existed
    // at delete time, and a reply / review / photo part still in flight when
    // the delete landed would otherwise arrive afterwards and resurrect a
    // piece of it, orphaned under a parent that no longer exists.
    final parent = post.parentId;
    if (parent != null && _deletedIds.contains(parent)) return;
    final existing = _posts.indexWhere((p) => p.id == post.id);
    if (existing != -1) {
      // A listing update (sold, edited price) arrives as the same post with
      // a higher revision. Only higher: the mailbox replays old copies, and
      // a stale replay must never roll a sold flag back.
      final old = _posts[existing];
      if (post.isListing &&
          old.isListing &&
          post.listingRev > old.listingRev) {
        _posts[existing] = post;
        _save();
        notifyListeners();
      }
      return;
    }
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
    // The whole subtree goes, not just the direct children: a reply's own
    // replies would otherwise survive pointing at a parent that no longer
    // exists — invisible in the thread but still sitting in the timeline.
    final doomed = <String>{postId};
    for (var grew = true; grew;) {
      grew = false;
      for (final p in _posts) {
        if (doomed.contains(p.id)) continue;
        if (doomed.contains(p.parentId) || doomed.contains(p.repostOfId)) {
          doomed.add(p.id);
          grew = true;
        }
      }
    }
    // Tombstone everything that goes, so no stale copy — cloud blob or queued
    // relay event — can bring any of it back.
    _deletedIds.addAll(doomed);
    final gone = [
      for (final p in _posts)
        if (doomed.contains(p.id)) p
    ];
    _posts.removeWhere((p) => doomed.contains(p.id));
    // Hand each surviving parent/original its counter back. Posts that went
    // with the cascade are skipped — there's nothing left to decrement.
    for (final p in gone) {
      final parentId = p.parentId;
      if (parentId != null && !doomed.contains(parentId)) {
        final i = _posts.indexWhere((x) => x.id == parentId);
        if (i >= 0 && _posts[i].replies > 0) {
          _posts[i] = _posts[i].copyWith(replies: _posts[i].replies - 1);
        }
      }
      final targetId = p.repostOfId;
      if (targetId != null && !doomed.contains(targetId)) {
        final i = _posts.indexWhere((x) => x.id == targetId);
        if (i >= 0 && _posts[i].reposts > 0) {
          _posts[i] = _posts[i].copyWith(reposts: _posts[i].reposts - 1);
        }
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
    final incoming = [
      for (final m in raw.whereType<Map>())
        FeedPost.fromJson(Map<String, dynamic>.from(m))
    ].where((p) => !_deletedIds.contains(p.id)).toList();
    final incomingIds = {for (final p in incoming) p.id};
    // Merge, don't replace. A restore pulls a blob that was uploaded at some
    // earlier moment; anything posted since (or while offline, before the
    // upload landed) isn't in it, and wholesale replacement would silently
    // destroy it. Tombstones still take out anything genuinely deleted.
    final localOnly = [
      for (final p in _posts)
        if (!incomingIds.contains(p.id) && !_deletedIds.contains(p.id)) p
    ];
    _posts
      ..clear()
      ..addAll(incoming)
      ..addAll(localOnly);
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
        _likedBy
          ..clear()
          ..addAll(
              (decoded['likedBy'] as List? ?? const []).whereType<String>());
        _votedBy
          ..clear()
          ..addAll({
            for (final e in (decoded['votedBy'] as Map? ?? const {}).entries)
              if (e.key is String && e.value is num)
                e.key as String: (e.value as num).toInt()
          });
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
            // The replay guards have to outlive the process: a mailbox row
            // whose delete failed comes back next launch, and without these
            // it would be counted a second time.
            'likedBy': _likedBy.toList(),
            'votedBy': _votedBy,
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
    _votedBy.clear();
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
