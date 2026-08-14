import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_state.dart';
import '../models/feed_notification.dart';
import '../payments/payment_service.dart';
import '../relay/relay_config.dart';
import 'feed_prefs.dart';
import 'push_service.dart';
import '../relay/relay_service.dart';
import 'score_store.dart';
import 'session.dart';

/// One post in a server's X-style feed.
class FeedPost {
  final String id;
  final String communityId;
  final String authorName;

  /// Username without '@' ('you' for the local user).
  final String authorUsername;

  /// The author's phone digits, so a reader can spark them. Rides only the
  /// SEALED server bus — never the public feed — and reveals nothing members
  /// don't already hold: the roster this bus runs on is keyed by digits.
  /// '' on legacy posts (spark simply isn't offered there).
  final String authorPhone;
  final DateTime time;
  final String text;
  final int likes;

  /// How many members have opened this post — unique viewers, counted
  /// once each through the same replay-guarded fan-out likes use. A
  /// number only; who viewed is a dedup key, never a surface.
  final int views;
  final int reposts;
  final int replies;
  final bool liked;
  final bool reposted;

  /// Sparks — what Damus/Nostr call "zaps": small real-money tips pinned to
  /// a post. The
  /// money itself moves person-to-person over Stripe BEFORE the counter
  /// moves; these fields are only the public tally. [sparks] is how many,
  /// [sparkCents] their total, [sparked] whether this device sent one.
  final int sparks;
  final int sparkCents;
  final bool sparked;

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

  /// Whether the seller has marked this listing reserved (on hold for a
  /// buyer, not yet sold). Presentation only — the item stays in the shop
  /// and searchable, wearing a "Reserved" badge — so a change of mind is one
  /// tap back. A sold listing is never also reserved.
  final bool listingReserved;

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

  /// On a BUYER REVIEW: the handle of the person being reviewed — the buyer
  /// the seller sold to. Empty on every other post, and that emptiness is
  /// what tells the two directions apart: a review with it set points
  /// seller → buyer, one without it points buyer → seller.
  ///
  /// It RIDES THE WIRE, unlike the sold-to record it comes from, and that is
  /// a real disclosure rather than an oversight: another device cannot
  /// compute somebody's buyer rating without knowing whose it is. Leaving a
  /// buyer review therefore says publicly that this person bought this item
  /// — the same bargain every marketplace's feedback makes, and the UI says
  /// so before you post one.
  final String buyerHandle;

  /// True for a review of a BUYER. [isReview] stays true for both directions
  /// (both carry a rating); this is what separates them.
  bool get isBuyerReview => rating > 0 && buyerHandle.isNotEmpty;

  /// On a listing: SHA-256 of the sale code the seller minted at the sold
  /// handshake — the code itself goes to the buyer over the E2E chat and is
  /// never broadcast, so the hash lets a copy of the listing check a typed
  /// code without the code being public. '' until a sale mints one.
  final String saleCodeHash;

  /// On a review: the author typed the sale code and it matched the
  /// listing's hash — a confirmed purchase rather than a drive-by opinion.
  /// Applied as sent, like [authorVerified]: the sender-key signature stops
  /// forging WHO wrote it, and this claim is theirs.
  final bool confirmedPurchase;

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

  /// How a listing changes hands: '' (unsaid), 'pickup', 'delivery',
  /// 'shipping'. A buyer's first question after the price, and one the
  /// description used to have to answer in prose.
  final String listingDelivery;

  /// How many are for sale. 1 unless the seller says otherwise; 0 is never
  /// stored, because a listing of nothing is a sold listing.
  final int listingQuantity;

  /// Whether the seller will talk about the price. Distinct from a low price:
  /// "firm" saves both sides a conversation neither wanted.
  final bool listingOffers;

  /// Where the item is, as a human-readable place ('' = unsaid). A name and
  /// not coordinates: this rides the relay to everyone in the server, and
  /// "Bloor & Bathurst" is what a buyer needs, while a lat/lng pair to five
  /// decimal places is somebody's front door.
  final String listingPlace;

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
  /// Optional brand/make line for a listing ('' = none).
  final String listingBrand;

  /// Category-specific attributes for a listing — bedrooms and rent period
  /// for a property, mileage and year for a vehicle, and so on. A flat
  /// string map keyed by the field's label, so ONE field carries every
  /// category's extras without a typed column per attribute; the spec that
  /// says which keys a category asks for lives in the marketplace UI
  /// (kCategoryFields), not here. Empty for anything that carries none.
  final Map<String, String> listingAttributes;

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
    this.authorPhone = '',
    required this.time,
    required this.text,
    this.likes = 0,
    this.views = 0,
    this.reposts = 0,
    this.replies = 0,
    this.liked = false,
    this.reposted = false,
    this.sparks = 0,
    this.sparkCents = 0,
    this.sparked = false,
    this.parentId,
    this.gifUrl,
    this.repostOfId,
    this.edited = false,
    this.pinned = false,
    this.priceCents,
    this.listingCategory = '',
    this.listingCondition = '',
    this.listingSold = false,
    this.listingReserved = false,
    this.listingRev = 0,
    this.authorVerified = false,
    this.rating = 0,
    this.saleCodeHash = '',
    this.buyerHandle = '',
    this.confirmedPurchase = false,
    this.mediaPart = 0,
    this.listingVideo = '',
    this.listingDelivery = '',
    this.listingQuantity = 1,
    this.listingOffers = false,
    this.listingPlace = '',
    this.prevPriceCents = 0,
    this.listingBrand = '',
    this.listingAttributes = const {},
    this.pollQuestion = '',
    this.pollOptions = const [],
    this.pollVotes = const [],
    this.pollMyVote = -1,
  });

  FeedPost copyWith({
    int? likes,
    int? views,
    int? reposts,
    int? replies,
    bool? liked,
    bool? reposted,
    int? sparks,
    int? sparkCents,
    bool? sparked,
    String? text,
    bool? edited,
    bool? pinned,
    bool? listingSold,
    bool? listingReserved,
    int? listingRev,
    String? saleCodeHash,
    DateTime? time,
    List<int>? pollVotes,
    int? pollMyVote,
  }) =>
      FeedPost(
        id: id,
        communityId: communityId,
        authorName: authorName,
        authorUsername: authorUsername,
        authorPhone: authorPhone,
        time: time ?? this.time,
        text: text ?? this.text,
        likes: likes ?? this.likes,
        views: views ?? this.views,
        reposts: reposts ?? this.reposts,
        replies: replies ?? this.replies,
        liked: liked ?? this.liked,
        reposted: reposted ?? this.reposted,
        sparks: sparks ?? this.sparks,
        sparkCents: sparkCents ?? this.sparkCents,
        sparked: sparked ?? this.sparked,
        parentId: parentId,
        gifUrl: gifUrl,
        repostOfId: repostOfId,
        edited: edited ?? this.edited,
        pinned: pinned ?? this.pinned,
        priceCents: priceCents,
        listingCategory: listingCategory,
        listingCondition: listingCondition,
        listingSold: listingSold ?? this.listingSold,
        listingReserved: listingReserved ?? this.listingReserved,
        listingRev: listingRev ?? this.listingRev,
        authorVerified: authorVerified,
        rating: rating,
        saleCodeHash: saleCodeHash ?? this.saleCodeHash,
        buyerHandle: buyerHandle,
        confirmedPurchase: confirmedPurchase,
        mediaPart: mediaPart,
        listingVideo: listingVideo,
        listingDelivery: listingDelivery,
        listingQuantity: listingQuantity,
        listingOffers: listingOffers,
        listingPlace: listingPlace,
        prevPriceCents: prevPriceCents,
        listingBrand: listingBrand,
        listingAttributes: listingAttributes,
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
        if (views > 0) 'views': views,
        'reposts': reposts,
        'replies': replies,
        'liked': liked,
        'reposted': reposted,
        if (authorPhone.isNotEmpty) 'authorPhone': authorPhone,
        if (sparks > 0) ...{'sparks': sparks, 'sparkCents': sparkCents},
        if (sparked) 'sparked': true,
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
          if (listingReserved) 'listingReserved': true,
          'listingRev': listingRev,
        },
        if (authorVerified) 'authorVerified': true,
        if (rating > 0) 'rating': rating,
        if (saleCodeHash.isNotEmpty) 'saleCodeHash': saleCodeHash,
        if (buyerHandle.isNotEmpty) 'buyerHandle': buyerHandle,
        if (confirmedPurchase) 'confirmedPurchase': true,
        if (mediaPart > 0) 'mediaPart': mediaPart,
        if (listingVideo.isNotEmpty) 'listingVideo': listingVideo,
        if (listingDelivery.isNotEmpty) 'listingDelivery': listingDelivery,
        if (listingQuantity != 1) 'listingQuantity': listingQuantity,
        if (listingOffers) 'listingOffers': true,
        if (listingPlace.isNotEmpty) 'listingPlace': listingPlace,
        if (prevPriceCents > 0) 'prevPriceCents': prevPriceCents,
        if (listingBrand.isNotEmpty) 'listingBrand': listingBrand,
        if (listingAttributes.isNotEmpty)
          'listingAttributes': listingAttributes,
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
        views: j['views'] as int? ?? 0,
        reposts: j['reposts'] as int? ?? 0,
        replies: j['replies'] as int? ?? 0,
        liked: j['liked'] as bool? ?? false,
        reposted: j['reposted'] as bool? ?? false,
        authorPhone: j['authorPhone'] as String? ?? '',
        sparks: (j['sparks'] as num?)?.toInt() ?? 0,
        sparkCents: (j['sparkCents'] as num?)?.toInt() ?? 0,
        sparked: j['sparked'] as bool? ?? false,
        parentId: j['parentId'] as String?,
        gifUrl: j['gifUrl'] as String?,
        repostOfId: j['repostOfId'] as String?,
        edited: j['edited'] as bool? ?? false,
        pinned: j['pinned'] as bool? ?? false,
        priceCents: (j['priceCents'] as num?)?.toInt(),
        listingCategory: j['listingCategory'] as String? ?? '',
        listingCondition: j['listingCondition'] as String? ?? '',
        listingSold: j['listingSold'] as bool? ?? false,
        listingReserved: j['listingReserved'] as bool? ?? false,
        listingRev: (j['listingRev'] as num?)?.toInt() ?? 0,
        authorVerified: j['authorVerified'] as bool? ?? false,
        rating: (j['rating'] as num?)?.toInt() ?? 0,
        saleCodeHash: j['saleCodeHash'] as String? ?? '',
        buyerHandle: j['buyerHandle'] as String? ?? '',
        confirmedPurchase: j['confirmedPurchase'] as bool? ?? false,
        mediaPart: (j['mediaPart'] as num?)?.toInt() ?? 0,
        listingVideo: j['listingVideo'] as String? ?? '',
        listingDelivery: j['listingDelivery'] as String? ?? '',
        listingQuantity: (j['listingQuantity'] as num?)?.toInt() ?? 1,
        listingOffers: j['listingOffers'] as bool? ?? false,
        listingPlace: j['listingPlace'] as String? ?? '',
        prevPriceCents: (j['prevPriceCents'] as num?)?.toInt() ?? 0,
        listingBrand: j['listingBrand'] as String? ?? '',
        listingAttributes: (j['listingAttributes'] as Map?)?.map(
                (k, v) => MapEntry('$k', '$v')) ??
            const {},
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

  /// Posts swiped out of the alerts tab. Narrower than [_hiddenIds] on
  /// purpose: dismissing an alert about a post says "stop announcing this",
  /// not "I never want to see it" — the post stays in its server's feed.
  final Set<String> _alertGoneIds = {};

  /// Whether [postId] is the Spark practice bot's post — a device-local
  /// fixture that exists only while payments test mode is on. It is never
  /// broadcast, never backfilled to joiners, and hidden the moment test
  /// mode turns off, which is what keeps it on the right side of the
  /// no-fake-data rule: nobody but the person who summoned it ever sees it.
  static bool isSparkBotPost(String postId) => postId.startsWith('spark_bot_');

  /// Summons (or refreshes) the Spark practice bot in [communityId]: one
  /// post by @sparkbot with a placeholder payment address, so the whole
  /// Spark flow can be walked in payments test mode without a second person
  /// or a real charge. Local to this device only.
  FeedPost addSparkBot(String communityId) {
    final id = 'spark_bot_$communityId';
    _posts.removeWhere((p) => p.id == id);
    _deletedIds.remove(id); // deleting it and summoning again must work
    final post = FeedPost(
      id: id,
      communityId: communityId,
      authorName: 'Sparky',
      authorUsername: 'sparkbot',
      // A reserved fake number (Stripe's test range): routable by the
      // simulated flow, owned by nobody real.
      authorPhone: '15005550006',
      time: DateTime.now(),
      text: 'I\'m Sparky, your practice bot. Tap the amber bolt below to '
          'try Sparks — payments test mode is on, so nothing is charged. '
          'I disappear when test mode turns off. ⚡',
    );
    _posts.add(post);
    _save();
    notifyListeners();
    return post;
  }

  /// What a brand-new member of [communityId] should be handed: the live
  /// listings first (they are what the marketplace shows and what "doesn't
  /// show up for everyone" was), then the newest other posts, capped so a
  /// years-old server doesn't flood a mailbox. Broadcast has no history —
  /// without this, a post made before someone joined never existed for them.
  List<FeedPost> backfillFor(String communityId, {int max = 60}) {
    final all = _posts
        .where((p) => p.communityId == communityId && !isSparkBotPost(p.id))
        .toList()
      ..sort((a, b) => b.time.compareTo(a.time));
    final listings =
        all.where((p) => p.isListing && !p.listingSold).toList();
    final rest = all.where((p) => !p.isListing || p.listingSold).toList();
    return [...listings, ...rest].take(max).toList();
  }

  /// Accounts whose interactions no longer raise an alert.
  ///
  /// SEPARATE FROM [_mutedUsernames] on purpose, and narrower. Muting somebody
  /// hides everything they post; muting their notifications only stops the
  /// buzz — you still see their replies when you open the thread. "Mute
  /// notifications" is offered on an alert, so it has to mean what it says
  /// there rather than quietly doing the larger thing.
  final Set<String> _mutedNotifiers = {};

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

  /// Replay guard for view events — same job as [_likedBy].
  final Set<String> _postViewedBy = {};

  // Spark event ids already counted. Unlike likes a spark is not a toggle —
  // the same person can spark twice — so idempotency keys on the event.
  final Set<String> _sparkIds = {};

  // Where each voter currently stands on each poll, so a replayed vote can't
  // double-count and a switch moves the tally instead of adding to it.
  final Map<String, int> _votedBy = {};

  /// Feed interactions with you, newest first.
  List<FeedNotification> get notifications =>
      List.unmodifiable(_notifications);

  /// How many are still unseen (drives the tab badge).
  int get unseenNotificationCount =>
      _notifications.where((n) => !n.seen).length;

  /// Whether alerts from [username] are silenced.
  bool notificationsMuted(String username) =>
      username.isNotEmpty && _mutedNotifiers.contains(username.toLowerCase());

  /// Raises an on-device notification for a feed/community interaction — the
  /// same events the Alerts tab lists, so anything that shows there can also
  /// buzz. On-device only ([PushService.localNotify]): the device already
  /// learned of this over the relay, so there's no server round trip and no
  /// cross-user push machinery. Gated on the master notifications toggle; the
  /// preview is dropped when private notifications are on, matching the
  /// server-side push policy. Callers have already applied the per-actor mute.
  void _alertFor(FeedNotification note) {
    if (!AppState.notificationsEnabled.value) return;
    final actor = note.actorName.trim().isEmpty ? 'Someone' : note.actorName;
    final verb = switch (note.type) {
      FeedNotificationType.reply => 'replied to you',
      FeedNotificationType.mention => 'mentioned you',
      FeedNotificationType.repost => 'reposted you',
      FeedNotificationType.like => 'liked your post',
      FeedNotificationType.spark => 'sparked your post',
      FeedNotificationType.review => 'reviewed your listing',
      FeedNotificationType.channelMention => note.channelName.isEmpty
          ? 'mentioned you'
          : 'mentioned you in #${note.channelName}',
    };
    PushService.instance.localNotify(
      title: '$actor $verb',
      body: AppState.privateNotifications.value ? '' : note.preview,
    );
  }

  /// Silences or unsilences alerts from [username]; returns true when now
  /// muted. Existing alerts stay — muting is about what happens next, and
  /// sweeping the list would look like the app deleting your history.
  bool toggleNotificationMute(String username) {
    final u = username.toLowerCase();
    if (u.isEmpty) return false;
    final nowMuted = !_mutedNotifiers.remove(u);
    if (nowMuted) _mutedNotifiers.add(u);
    _save();
    notifyListeners();
    return nowMuted;
  }

  /// Removes a post from the alerts tab only — it stays in its server's
  /// feed. See [_alertGoneIds].
  void dismissAlertPost(String id) {
    if (!_alertGoneIds.add(id)) return;
    _save();
    notifyListeners();
  }

  /// Bulk form of [dismissAlertPost], for "Clear all alerts" — one save and
  /// one rebuild instead of one per row.
  void dismissAlertPosts(Iterable<String> ids) {
    final before = _alertGoneIds.length;
    _alertGoneIds.addAll(ids);
    if (_alertGoneIds.length == before) return;
    _save();
    notifyListeners();
  }

  /// Removes one alert. Local only: an alert is this device's note that
  /// something happened, not a thing anybody else can see.
  void dismissNotification(String id) {
    final before = _notifications.length;
    _notifications.removeWhere((n) => n.id == id);
    if (_notifications.length == before) return;
    _save();
    notifyListeners();
  }

  /// Removes every alert.
  void clearNotifications() {
    if (_notifications.isEmpty) return;
    _notifications.clear();
    _save();
    notifyListeners();
  }

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
    } else if (post.isReview &&
        post.parentId != null &&
        myPostIds.contains(post.parentId)) {
      // Checked ahead of the generic parentId branch below: a review's
      // parentId is the listing id, which would otherwise classify as an
      // ordinary "replied to you" — true of the wire shape, false of what
      // it actually is.
      type = FeedNotificationType.review;
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
    final note = FeedNotification(
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
    );
    _notifications.insert(0, note);
    if (_notifications.length > 50) _notifications.removeLast();
    _alertFor(note);
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

  /// Listings this device opened, newest first, capped — the "recently
  /// viewed" shelf. Ids only; the shelf resolves them against the live
  /// posts so a deleted listing simply stops appearing.
  final List<String> _recentlyViewedIds = [];
  static const int maxRecentlyViewed = 8;

  /// Searches this device chose to keep, newest first, capped. Matching is
  /// the browse screen's own filters re-run (pure helpers in the
  /// marketplace file); the store only remembers what was asked and when
  /// it was last looked at — which is what the "N new" badge counts from.
  final List<SavedSearch> _savedSearches = [];
  static const int maxSavedSearches = 6;

  List<SavedSearch> get savedSearches => List.unmodifiable(_savedSearches);

  /// Keeps a search. An empty one is refused (it would match everything,
  /// so "new" would mean "any listing at all"), and saving the same search
  /// twice moves the existing one to the front instead of duplicating it.
  SavedSearch? addSavedSearch(
      {String query = '', String category = '', int? minCents, int? maxCents}) {
    final q = query.trim();
    if (q.isEmpty && category.isEmpty && minCents == null && maxCents == null) {
      return null;
    }
    final existing = _savedSearches.indexWhere((s) =>
        s.query.toLowerCase() == q.toLowerCase() &&
        s.category == category &&
        s.minCents == minCents &&
        s.maxCents == maxCents);
    if (existing != -1) {
      final s = _savedSearches.removeAt(existing);
      _savedSearches.insert(0, s);
      _save();
      notifyListeners();
      return s;
    }
    final s = SavedSearch(
      id: 'ss${_nextId++}',
      query: q,
      category: category,
      minCents: minCents,
      maxCents: maxCents,
      lastSeenAt: DateTime.now(),
    );
    _savedSearches.insert(0, s);
    if (_savedSearches.length > maxSavedSearches) {
      _savedSearches.removeRange(maxSavedSearches, _savedSearches.length);
    }
    _save();
    notifyListeners();
    return s;
  }

  void removeSavedSearch(String id) {
    _savedSearches.removeWhere((s) => s.id == id);
    _save();
    notifyListeners();
  }

  /// Marks [id] as looked-at now, so its badge starts counting from zero.
  void touchSavedSearch(String id) {
    final i = _savedSearches.indexWhere((s) => s.id == id);
    if (i == -1) return;
    _savedSearches[i] = _savedSearches[i].seenNow();
    _save();
    notifyListeners();
  }

  /// Records that [listingId] was opened. A no-op when it is already at
  /// the front — the listing screen calls this from build, and mutating
  /// (then notifying) on every rebuild would be a loop.
  void noteViewed(String listingId) {
    if (_recentlyViewedIds.firstOrNull == listingId) return;
    _recentlyViewedIds
      ..remove(listingId)
      ..insert(0, listingId);
    if (_recentlyViewedIds.length > maxRecentlyViewed) {
      _recentlyViewedIds.removeRange(
          maxRecentlyViewed, _recentlyViewedIds.length);
    }
    _save();
    notifyListeners();
  }

  /// The shelf, resolved: still-existing listings in viewed order.
  List<FeedPost> recentlyViewed() {
    final out = <FeedPost>[];
    for (final id in _recentlyViewedIds) {
      final i = _posts.indexWhere((p) => p.id == id && p.isListing);
      if (i != -1) out.add(_posts[i]);
    }
    return out;
  }

  /// Saved listings whose price DROPPED and still stands below the old
  /// ask — the thing a saver actually wants to hear about. Sold ones are
  /// out: a discount on the unbuyable is noise.
  List<FeedPost> savedPriceDrops() => [
        for (final p in _posts)
          if (p.isListing &&
              !p.listingSold &&
              _savedIds.contains(p.id) &&
              p.prevPriceCents > (p.priceCents ?? 0))
            p
      ];

  /// Every saved listing this device can still see, newest first — the
  /// wishlist. Hidden/muted ones drop out like they do in the grid; sold ones
  /// stay (a saver wants to know it went), and price-dropped ones keep their
  /// struck-through "was" price so the screen can highlight the deal.
  List<FeedPost> savedListings() => [
        for (final p in _posts)
          if (p.isListing &&
              _savedIds.contains(p.id) &&
              !_hiddenIds.contains(p.id) &&
              !_mutedUsernames.contains(p.authorUsername.toLowerCase()))
            p
      ]..sort((a, b) => b.time.compareTo(a.time));

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
  /// Every post this device holds, across all communities, read-only.
  /// Earnings tallies sparks and sales from it — nothing else should need
  /// the unfiltered list, so think twice before reaching for it.
  List<FeedPost> get allPosts => List.unmodifiable(_posts);

  /// their parent (see [repliesTo]). With [onlyUsernames], keeps posts from
  /// those authors and your own. No seeded/demo content: every post here
  /// was written by a real person on this device or community — with ONE
  /// stated exception, the Spark practice bot, which the owner summons
  /// explicitly and which only renders while payments test mode is on.
  List<FeedPost> postsFor(String communityId, {Set<String>? onlyUsernames}) {
    var posts = _posts.where((p) =>
        p.communityId == communityId &&
        p.parentId == null &&
        // Listings live in the Marketplace, not the timeline — a feed full
        // of price tags reads as ads.
        !p.isListing &&
        (!isSparkBotPost(p.id) || PaymentService.instance.testMode.value) &&
        !_hiddenIds.contains(p.id) &&
        // The reader's own shape: muted words and (optionally) reposts.
        !FeedPrefs.instance.hides(p.text) &&
        !(FeedPrefs.instance.hideReposts && p.repostOfId != null) &&
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
    final myUsername = AppState.profile.value.username;
    final list = _posts
        .where((p) =>
            p.parentId == null &&
            !p.isListing &&
            // Repost entries carry no text of their own — the activity
            // preview shows originals only.
            p.repostOfId == null &&
            // Your own posts are not activity: you were there when you
            // posted them. Without this, posting in a server put your own
            // post at the top of the Alerts tab as if it were news.
            p.authorUsername != 'you' &&
            (myUsername.isEmpty ||
                p.authorUsername.toLowerCase() != myUsername.toLowerCase()) &&
            !_hiddenIds.contains(p.id) &&
            !_alertGoneIds.contains(p.id) &&
            !_mutedUsernames.contains(p.authorUsername.toLowerCase()))
        .toList()
      ..sort((a, b) => b.time.compareTo(a.time));
    return list.take(limit).toList();
  }

  /// Seeds the store with posts by arbitrary authors, which [add] cannot do
  /// — it always posts as the signed-in user, so a stranger's reply is
  /// unreachable without this.
  @visibleForTesting
  void debugSetPosts(List<FeedPost> posts) {
    _posts
      ..clear()
      ..addAll(posts);
    notifyListeners();
  }

  /// The author's own replies to [postId], oldest first — a self-thread.
  /// Same idea and same reasoning as the public feed's [selfThreadOf]: one
  /// piece of writing that ran past a post's length, rather than other people
  /// answering.
  List<FeedPost> selfThreadOf(String postId) {
    final root = postById(postId);
    if (root == null) return const [];
    final list = _posts
        .where((p) =>
            p.parentId == postId &&
            p.authorUsername == root.authorUsername)
        .toList()
      ..sort((a, b) => a.time.compareTo(b.time));
    return list;
  }

  /// The replies under a post, oldest first (thread order).
  /// The chain of posts [postId] is a reply to, ROOT FIRST. Same contract,
  /// same reasoning and same guards as the public feed's — see
  /// PublicFeedStore.ancestorsOf. Parent ids ride the relay from other
  /// devices, so a self-referencing or looping row is one malformed message
  /// away and an unbounded walk would hang the thread.
  static const int maxThreadDepth = 25;

  List<FeedPost> ancestorsOf(String postId) {
    final chain = <FeedPost>[];
    final seen = <String>{postId};
    var current = postById(postId);
    while (current?.parentId != null && chain.length < maxThreadDepth) {
      final parentId = current!.parentId!;
      if (!seen.add(parentId)) break;
      final parent = postById(parentId);
      if (parent == null) break;
      chain.add(parent);
      current = parent;
    }
    return chain.reversed.toList();
  }

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
      // So readers can spark this post. Digits members already have.
      authorPhone: RelayService.digits(
          Session.instance.user.value?.phone ?? ''),
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
    // A post earns like a forum post does; a reply is the room's smaller
    // coin, same as a forum comment.
    ScoreStore.instance.award(
        parentId == null
            ? ScoreStore.pointsPerFeedPost
            : ScoreStore.pointsPerForumComment,
        source: parentId == null ? 'feed' : 'forumComment');
    return post;
  }

  /// Drops blank answers and trims the rest — an unanswered category field
  /// is absent, not an empty row, so the detail table shows only what was
  /// actually said.
  static Map<String, String> _cleanAttributes(Map<String, String> raw) => {
        for (final e in raw.entries)
          if (e.value.trim().isNotEmpty) e.key: e.value.trim(),
      };

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
    String delivery = '',
    int quantity = 1,
    bool offers = false,
    String place = '',
    int prevPriceCents = 0,
    String brand = '',
    Map<String, String> attributes = const {},
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
      listingDelivery: delivery,
      listingQuantity: quantity < 1 ? 1 : quantity,
      listingOffers: offers,
      listingPlace: place,
      // A seller can say what it USED to cost — shown struck through only
      // while it is higher than the ask, same as an edit-time price drop.
      prevPriceCents: prevPriceCents > priceCents ? prevPriceCents : 0,
      listingBrand: brand.trim(),
      listingAttributes: _cleanAttributes(attributes),
    );
    _posts.add(post);
    _addPhotoParts(post, extraPhotos);
    _save();
    notifyListeners();
    if (RelayConfig.isEnabled) RelayService.instance.sendFeedPost(post);
    ScoreStore.instance
      ..award(ScoreStore.pointsPerListing, source: 'listing')
      ..recordFlag('listed_item');
    return post;
  }

  /// Clones one of your listings into a fresh, unsold, un-reserved copy —
  /// same title, price, category, condition and photos, a new id and a new
  /// timestamp. For a seller relisting the same kind of thing without
  /// retyping it. Returns the new listing, or null if [postId] isn't a
  /// listing of yours.
  FeedPost? duplicateListing(String postId) {
    final srcIndex =
        _posts.indexWhere((p) => p.id == postId && p.isListing);
    if (srcIndex == -1) return null;
    final src = _posts[srcIndex];
    final me = AppState.profile.value.username;
    final mine = src.authorUsername == 'you' ||
        (me.isNotEmpty && src.authorUsername == me);
    if (!mine) return null;
    final photos = listingPhotos(postId);
    final title = src.text.split('\n').first;
    final description =
        src.text.contains('\n') ? src.text.substring(title.length + 1) : '';
    return addListing(
      src.communityId,
      title: title,
      priceCents: src.priceCents ?? 0,
      category: src.listingCategory,
      description: description,
      photoUrl: photos.isNotEmpty ? photos.first : src.gifUrl,
      extraPhotos: photos.length > 1 ? photos.sublist(1) : const [],
      videoPath: src.listingVideo,
      condition: src.listingCondition,
      delivery: src.listingDelivery,
      quantity: src.listingQuantity,
      offers: src.listingOffers,
      place: src.listingPlace,
      brand: src.listingBrand,
      attributes: Map<String, String>.from(src.listingAttributes),
    );
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

  /// SHA-256 of a sale code, salted with a fixed label so the hash cannot
  /// be mistaken for (or reused as) any other hash in the app.
  ///
  /// [buyer] BINDS the code to one buyer's handle: when the seller mints for a
  /// specific buyer, only that buyer — typing the code under their own handle —
  /// reproduces the hash. So a code that leaks (or that a seller hands a friend)
  /// earns nobody else the confirmed-purchase chip, because a different handle
  /// hashes to something else. Empty [buyer] is the old, unbound behavior, kept
  /// so a sale to a handle-less account still works (it just can't be bound).
  static String saleCodeHashOf(String code, {String buyer = ''}) {
    final b = buyer.trim().toLowerCase();
    final payload = b.isEmpty ? code.trim() : '${code.trim()}:$b';
    return sha256.convert(utf8.encode('okay-sale:$payload')).toString();
  }

  /// listing id → the handle the seller marked it sold to.
  ///
  /// LOCAL ONLY, and deliberately not a field on the listing: a listing is
  /// published to a world-readable table, so a `soldTo` on the post would
  /// broadcast who bought what to everyone, for every sale, whether or not
  /// anybody ever writes a review. The sale code already goes to that buyer
  /// over the E2E chat and only its HASH rides — this keeps the same
  /// promise. It exists so the seller's own device can answer "who was this
  /// sale for" when they come to review them.
  final Map<String, String> _soldTo = {};

  /// Who [listingId] was marked sold to, '' when it was not marked at all.
  String soldTo(String listingId) => _soldTo[listingId] ?? '';

  /// Mints the six-digit sale code for an OWN listing at the sold handshake,
  /// BOUND to [buyerHandle] (the buyer the seller marked sold-to). Only the
  /// hash rides the listing broadcast — the code itself goes to the buyer over
  /// the E2E chat, and the buyer's handle never rides at all — so any member's
  /// copy can check a typed code (against their own handle) without either the
  /// code or the buyer's identity being public. Re-minting replaces the old
  /// hash: one live code per sale, the newest one.
  String? mintSaleCode(String listingId, {String buyerHandle = ''}) {
    final i = _posts.indexWhere((p) => p.id == listingId);
    if (i == -1 || !_posts[i].isListing) return null;
    final post = _posts[i];
    final me = AppState.profile.value.username;
    final mine = post.authorUsername == 'you' ||
        (me.isNotEmpty && post.authorUsername == me);
    if (!mine) return null;
    final code = (Random.secure().nextInt(900000) + 100000).toString();
    final updated = post.copyWith(
        saleCodeHash: saleCodeHashOf(code, buyer: buyerHandle),
        listingRev: post.listingRev + 1);
    _posts[i] = updated;
    // Remembered on THIS device only — see [_soldTo].
    final handle = buyerHandle.trim().toLowerCase();
    if (handle.isNotEmpty) _soldTo[listingId] = handle;
    _save();
    notifyListeners();
    if (RelayConfig.isEnabled) RelayService.instance.sendFeedPost(updated);
    return code;
  }

  /// Whether [code], typed by [buyerHandle], is the sale code for [listingId].
  /// False when the listing never minted one — nothing can confirm against
  /// nothing — and false when the code was bound to a different buyer, which is
  /// the whole point: the confirmed chip belongs to the person the seller
  /// actually sold to, not to whoever gets hold of the number.
  bool saleCodeMatches(String listingId, String code,
      {String buyerHandle = ''}) {
    final i = _posts.indexWhere((p) => p.id == listingId);
    if (i == -1) return false;
    final hash = _posts[i].saleCodeHash;
    if (hash.isEmpty || code.trim().isEmpty) return false;
    // A code bound to a buyer needs that buyer's handle; try the bound form
    // first and fall back to the unbound form so an older listing (or a sale
    // to a handle-less account) still confirms.
    return saleCodeHashOf(code, buyer: buyerHandle) == hash ||
        saleCodeHashOf(code) == hash;
  }

  /// The active listings this device can see from [username] — a business
  /// contact's shop, resolved locally by handle with the same honesty as
  /// knownBusinessSeller: only what has already reached this device,
  /// because there is no server catalog to ask.
  List<FeedPost> listingsBySeller(String username) {
    final u = username.trim().toLowerCase();
    if (u.isEmpty || u == 'you') return const [];
    return listings(includeSold: false)
        .where((l) => l.authorUsername.toLowerCase() == u)
        .toList();
  }

  /// Writes (or rewrites) the local user's review of a listing.
  ///
  /// One voice per person: an existing review by this user is deleted first —
  /// which broadcasts its tombstone — and the new one posts in its place, so
  /// editing a review propagates with the machinery replies already have.
  /// Sellers cannot review their own listings; five stars you gave yourself
  /// would make every rating worthless.
  /// With [saleCode], a matching code marks the review a confirmed
  /// purchase; a wrong or absent code posts an ordinary (unconfirmed)
  /// review — an opinion is still allowed, it just doesn't wear the chip.
  bool addReview(String listingId,
      {required int rating, String text = '', String saleCode = ''}) {
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
      // Bound to the reviewer's OWN handle: the chip is earned only when the
      // person writing the review is the buyer the seller minted the code for.
      confirmedPurchase:
          saleCodeMatches(listingId, saleCode, buyerHandle: myUsername),
    );
    _posts.add(review);
    _save();
    notifyListeners();
    if (RelayConfig.isEnabled) RelayService.instance.sendFeedPost(review);
    return true;
  }

  /// The SELLER rates the buyer, after a sale they marked sold to them.
  ///
  /// The mirror of [addReview] and deliberately not the same function: the
  /// permission is inverted (only the listing's OWNER may write one), the
  /// target is a person rather than a listing, and there is no sale code —
  /// the seller does not prove the sale to themselves, [soldTo] already
  /// recorded who they marked it for. Returns false when there is nobody
  /// recorded, which is the honest answer for a listing sold outside the
  /// handshake: with no buyer named there is nobody to review.
  bool addBuyerReview(String listingId,
      {required int rating, String text = ''}) {
    final i = _posts.indexWhere((p) => p.id == listingId);
    if (i == -1 || !_posts[i].isListing) return false;
    final listing = _posts[i];
    final me = AppState.profile.value;
    final myUsername = me.username.isEmpty ? 'you' : me.username;
    final mine = listing.authorUsername == 'you' ||
        listing.authorUsername == myUsername;
    if (!mine) return false;
    final buyer = soldTo(listingId);
    if (buyer.isEmpty) return false;
    // Reviewing yourself is not a thing, however the handles line up.
    if (buyer == myUsername.toLowerCase()) return false;
    final clamped = rating.clamp(1, 5);
    final existing = myBuyerReviewOf(listingId);
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
      buyerHandle: buyer,
      // A seller reviewing their own completed sale is confirmed by
      // construction: they are the one who marked it sold.
      confirmedPurchase: true,
    );
    _posts.add(review);
    _save();
    notifyListeners();
    if (RelayConfig.isEnabled) RelayService.instance.sendFeedPost(review);
    return true;
  }

  /// This account's own buyer review of [listingId], if it wrote one.
  FeedPost? myBuyerReviewOf(String listingId) {
    final me = AppState.profile.value.username;
    final mine = me.isEmpty ? 'you' : me;
    for (final p in _posts) {
      if (p.parentId == listingId &&
          p.isBuyerReview &&
          (p.authorUsername == 'you' || p.authorUsername == mine)) {
        return p;
      }
    }
    return null;
  }

  /// The buyer reviews hanging off [listingId] — the other direction of
  /// [reviewsFor], which deliberately excludes them.
  List<FeedPost> buyerReviewsFor(String listingId) {
    final list = _posts
        .where((p) =>
            p.parentId == listingId &&
            p.isBuyerReview &&
            !_hiddenIds.contains(p.id) &&
            !_mutedUsernames.contains(p.authorUsername.toLowerCase()))
        .toList()
      ..sort((a, b) => b.time.compareTo(a.time));
    return list;
  }

  /// Every review OF [handle] as a buyer, newest first.
  List<FeedPost> buyerReviewsOf(String handle) {
    final h = handle.trim().toLowerCase();
    if (h.isEmpty) return const [];
    final list = _posts
        .where((p) =>
            p.isBuyerReview &&
            p.buyerHandle.toLowerCase() == h &&
            !_hiddenIds.contains(p.id) &&
            !_mutedUsernames.contains(p.authorUsername.toLowerCase()))
        .toList()
      ..sort((a, b) => b.time.compareTo(a.time));
    return list;
  }

  /// [handle]'s rating AS A BUYER — average and count, (0, 0) for somebody
  /// nobody has sold to. Kept apart from [sellerRating] on purpose: being
  /// good to deal with as a buyer and being good to buy from are different
  /// claims, and averaging them together would let one launder the other.
  (double, int) buyerRating(String handle) {
    final reviews = buyerReviewsOf(handle);
    if (reviews.isEmpty) return (0, 0);
    var sum = 0;
    for (final r in reviews) {
      sum += r.rating;
    }
    return (sum / reviews.length, reviews.length);
  }

  /// A listing's reviews, newest first.
  List<FeedPost> reviewsFor(String listingId) {
    final list = _posts
        .where((p) =>
            p.parentId == listingId &&
            p.isReview &&
            // A buyer review hangs off the same listing but is a review of
            // the BUYER — showing it here would read as somebody rating the
            // seller, and would land in sellerRating, which reads this.
            !p.isBuyerReview &&
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
    String? delivery,
    int? quantity,
    bool? offers,
    String? place,
    String? videoPath,
    String? condition,
    String? brand,
    Map<String, String>? attributes,
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
      listingReserved: post.listingReserved,
      listingRev: post.listingRev + 1,
      listingVideo: videoPath ?? post.listingVideo,
      listingDelivery: delivery ?? post.listingDelivery,
      listingQuantity: quantity ?? post.listingQuantity,
      listingOffers: offers ?? post.listingOffers,
      listingPlace: place ?? post.listingPlace,
      listingBrand: brand ?? post.listingBrand,
      // Replaced wholesale, not merged: editing a listing's category can
      // drop fields the old one had, so a stale attribute must not linger.
      listingAttributes: attributes != null
          ? _cleanAttributes(attributes)
          : post.listingAttributes,
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
    // A sold listing is never also reserved — the hold resolved into a sale.
    final updated = post.copyWith(
        listingSold: sold,
        listingReserved: sold ? false : post.listingReserved,
        listingRev: post.listingRev + 1);
    _posts[i] = updated;
    _save();
    notifyListeners();
    if (RelayConfig.isEnabled) RelayService.instance.sendFeedPost(updated);
    // Selling is the marketplace's whole point, so it pays the most. The
    // per-listing flag is the farm guard: un-marking and re-marking the
    // same listing sold cannot earn the points twice.
    if (sold && !ScoreStore.instance.flags.contains('sold_item_${post.id}')) {
      ScoreStore.instance
        ..recordFlag('sold_item_${post.id}')
        ..recordFlag('sold_item')
        ..award(ScoreStore.pointsPerSale, source: 'sale');
    }
    return true;
  }

  /// Flips a listing's reserved flag (own, unsold listings only) and tells
  /// the server. Reserving a sold listing is a no-op — the sale is the
  /// stronger truth. Rides the same revision ratchet as the sold flag so a
  /// stale replay can't undo it.
  bool setListingReserved(String postId, bool reserved) {
    final i = _posts.indexWhere((p) => p.id == postId);
    if (i == -1 || !_posts[i].isListing) return false;
    final post = _posts[i];
    final me = AppState.profile.value.username;
    final mine = post.authorUsername == 'you' ||
        (me.isNotEmpty && post.authorUsername == me);
    if (!mine || post.listingSold || post.listingReserved == reserved) {
      return false;
    }
    final updated = post.copyWith(
        listingReserved: reserved, listingRev: post.listingRev + 1);
    _posts[i] = updated;
    _save();
    notifyListeners();
    if (RelayConfig.isEnabled) RelayService.instance.sendFeedPost(updated);
    return true;
  }

  /// The soonest another post may follow the last — a spam brake at the
  /// composer, not a rule of the bus: sends still deliver, this is the
  /// button refusing to be hammered. Twenty seconds is invisible to a
  /// person and a wall to a script.
  static const Duration postCooldown = Duration(seconds: 20);
  DateTime? _lastAuthoredAt;

  /// How much longer the composer should refuse, or zero.
  Duration postCooldownLeft() {
    final at = _lastAuthoredAt;
    if (at == null) return Duration.zero;
    final left = postCooldown - DateTime.now().difference(at);
    return left.isNegative ? Duration.zero : left;
  }

  /// Stamped by the composer when a post actually goes out.
  void noteAuthored() => _lastAuthoredAt = DateTime.now();

  /// How long a listing must sit before its owner can re-top it.
  static const Duration bumpEvery = Duration(hours: 48);

  /// Whether [postId] can be bumped: yours, unsold, and at least
  /// [bumpEvery] old. The post's time IS the bump marker — sorting reads
  /// it, so the age check is the rate limit and bumping resets it in the
  /// same motion, with no second clock to fall out of step.
  bool canBumpListing(String postId) {
    final i = _posts.indexWhere((p) => p.id == postId);
    if (i == -1 || !_posts[i].isListing) return false;
    final post = _posts[i];
    final me = AppState.profile.value.username;
    final mine = post.authorUsername == 'you' ||
        (me.isNotEmpty && post.authorUsername == me);
    return mine &&
        !post.listingSold &&
        DateTime.now().difference(post.time) >= bumpEvery;
  }

  /// Re-tops a stale listing of yours: its time becomes now and the
  /// revision climbs, so other devices accept the fresher copy the same
  /// way they accept a sold flag — and a stale mailbox replay can never
  /// un-bump it.
  bool bumpListing(String postId) {
    if (!canBumpListing(postId)) return false;
    final i = _posts.indexWhere((p) => p.id == postId);
    final updated = _posts[i].copyWith(
        time: DateTime.now(), listingRev: _posts[i].listingRev + 1);
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
  void reply(String postId, String text, {String? gifUrl}) {
    final i = _posts.indexWhere((p) => p.id == postId);
    if (i < 0) return;
    final original = _posts[i];
    add(original.communityId, text, parentId: postId, gifUrl: gifUrl);
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

  /// Records that THIS member opened [postId], once ever: the local count
  /// moves and the view fans out to the other members like a like does.
  /// The guard key is the dedup and nothing else — who viewed is never a
  /// surface, here or anywhere.
  void recordPostView(String postId) {
    final i = _posts.indexWhere((p) => p.id == postId);
    if (i < 0) return;
    final me = AppState.profile.value;
    final username = me.username.isEmpty ? 'you' : me.username;
    final key = 'view_${postId}_$username';
    if (_postViewedBy.contains(key)) return;
    _postViewedBy.add(key);
    _posts[i] = _posts[i].copyWith(views: _posts[i].views + 1);
    _save();
    notifyListeners();
    if (RelayConfig.isEnabled) {
      RelayService.instance
          .sendFeedView(_posts[i].communityId, postId, viewerUsername: username);
    }
  }

  /// Applies a view that arrived from another member. Deduped like a like:
  /// a replayed event can't inflate the count.
  void applyRemoteView(String postId, {required String viewerUsername}) {
    final i = _posts.indexWhere((p) => p.id == postId);
    if (i < 0 || viewerUsername.isEmpty) return;
    final key = 'view_${postId}_$viewerUsername';
    if (_postViewedBy.contains(key)) return;
    _postViewedBy.add(key);
    _posts[i] = _posts[i].copyWith(views: _posts[i].views + 1);
    _save();
    notifyListeners();
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
        if (!notificationsMuted(likerUsername) &&
            !_notifications.any((n) => n.id == noteId)) {
          final note = FeedNotification(
            id: noteId,
            type: FeedNotificationType.like,
            communityId: p.communityId,
            actorName: likerName,
            actorUsername: likerUsername,
            time: DateTime.now(),
            threadPostId: postId,
          );
          _notifications.insert(0, note);
          if (_notifications.length > 50) _notifications.removeLast();
          _alertFor(note);
        }
      }
    }
    _save();
    notifyListeners();
  }

  /// Records MY spark on [postId] — called only AFTER its payment succeeded,
  /// because a counter that moves before the money is a lie on everyone's
  /// screen — and broadcasts it so the server's tallies converge.
  void spark(String postId, int cents) {
    final i = _posts.indexWhere((p) => p.id == postId);
    if (i < 0 || cents <= 0) return;
    final p = _posts[i];
    _posts[i] = p.copyWith(
        sparks: p.sparks + 1, sparkCents: p.sparkCents + cents, sparked: true);
    _save();
    notifyListeners();
    // The practice bot is a device-local fixture: telling the server about
    // sparks on it would broadcast a post nobody else has.
    if (isSparkBotPost(postId)) return;
    if (RelayConfig.isEnabled) {
      final me = AppState.profile.value;
      RelayService.instance.sendFeedSpark(
        p.communityId,
        postId,
        sparkId: 'spark_${postId}_${DateTime.now().microsecondsSinceEpoch}',
        cents: cents,
        name: me.name,
        username: me.username.isEmpty ? 'you' : me.username,
      );
    }
  }

  /// Applies someone else's spark. [sparkId] keys idempotency: a spark is not a
  /// toggle like a like — the same person can spark twice on purpose — so
  /// replay protection has to hang on the event, not the (post, actor) pair.
  void applyRemoteSpark(String postId,
      {required String sparkId,
      required int cents,
      required String sparkerName,
      required String sparkerUsername}) {
    if (cents <= 0 || _sparkIds.contains(sparkId)) return;
    final i = _posts.indexWhere((p) => p.id == postId);
    if (i < 0) return;
    _sparkIds.add(sparkId);
    final p = _posts[i];
    _posts[i] = p.copyWith(sparks: p.sparks + 1, sparkCents: p.sparkCents + cents);
    final me = AppState.profile.value;
    final myUsername = me.username.isEmpty ? 'you' : me.username;
    final mine = p.authorUsername == 'you' ||
        p.authorUsername.toLowerCase() == myUsername.toLowerCase();
    if (mine &&
        sparkerUsername.toLowerCase() != myUsername.toLowerCase() &&
        !notificationsMuted(sparkerUsername)) {
      final noteId = 'sparknote_$sparkId';
      if (!_notifications.any((n) => n.id == noteId)) {
        final note = FeedNotification(
          id: noteId,
          type: FeedNotificationType.spark,
          communityId: p.communityId,
          actorName: sparkerName,
          actorUsername: sparkerUsername,
          time: DateTime.now(),
          threadPostId: postId,
          preview: '\$${(cents / 100).toStringAsFixed(2)}',
        );
        _notifications.insert(0, note);
        if (_notifications.length > 50) _notifications.removeLast();
        _alertFor(note);
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
    // Muted at the door rather than filtered on the way out: an alert that
    // was never wanted should not sit in storage waiting to be hidden.
    if (notificationsMuted(note.actorUsername)) return;
    if (_notifications.any((n) => n.id == note.id)) return;
    _notifications.insert(0, note);
    if (_notifications.length > 50) _notifications.removeLast();
    _alertFor(note);
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
        _mutedNotifiers
          ..clear()
          ..addAll((decoded['notifmuted'] as List? ?? const [])
              .whereType<String>());
        _alertGoneIds
          ..clear()
          ..addAll((decoded['alertgone'] as List? ?? const [])
              .whereType<String>());
        _savedIds
          ..clear()
          ..addAll(
              (decoded['saved'] as List? ?? const []).whereType<String>());
        _recentlyViewedIds
          ..clear()
          ..addAll(
              (decoded['recents'] as List? ?? const []).whereType<String>());
        _savedSearches
          ..clear()
          ..addAll((decoded['searches'] as List? ?? const [])
              .whereType<Map>()
              .map((m) =>
                  SavedSearch.fromJson(Map<String, dynamic>.from(m))));
        _deletedIds
          ..clear()
          ..addAll(
              (decoded['deleted'] as List? ?? const []).whereType<String>());
        final soldRaw = decoded['soldto'];
        if (soldRaw is Map) {
          _soldTo
            ..clear()
            ..addEntries(soldRaw.entries
                .where((e) => e.value is String)
                .map((e) => MapEntry('${e.key}', e.value as String)));
        }
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
        _postViewedBy
          ..clear()
          ..addAll(
              (decoded['viewedBy'] as List? ?? const []).whereType<String>());
        _sparkIds
          ..clear()
          ..addAll(
              (decoded['sparkIds'] as List? ?? const []).whereType<String>());
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
            'notifmuted': _mutedNotifiers.toList(),
            'alertgone': _alertGoneIds.toList(),
            'saved': _savedIds.toList(),
            'recents': _recentlyViewedIds,
            'searches': [for (final s in _savedSearches) s.toJson()],
            'deleted': _deletedIds.toList(),
            'soldto': _soldTo,
            'notifs': [for (final n in _notifications) n.toJson()],
            // The replay guards have to outlive the process: a mailbox row
            // whose delete failed comes back next launch, and without these
            // it would be counted a second time.
            'likedBy': _likedBy.toList(),
            'viewedBy': _postViewedBy.toList(),
            'sparkIds': _sparkIds.toList(),
            'votedBy': _votedBy,
          }));
    } catch (_) {}
  }

  @visibleForTesting
  void resetForTest() {
    _posts.clear();
    _hiddenIds.clear();
    _mutedUsernames.clear();
    _mutedNotifiers.clear();
    _alertGoneIds.clear();
    _savedIds.clear();
    _recentlyViewedIds.clear();
    _savedSearches.clear();
    _lastAuthoredAt = null;
    _deletedIds.clear();
    _soldTo.clear();
    _notifications.clear();
    _likedBy.clear();
    _postViewedBy.clear();
    _sparkIds.clear();
    _votedBy.clear();
    _nextId = 1;
    notifyListeners();
  }
}

/// One kept marketplace search: what was typed and filtered, and when the
/// results were last looked at — listings newer than that are what the
/// "N new" badge counts. Matching itself lives with the browse filters
/// (pure helpers in the marketplace file), not here.
class SavedSearch {
  final String id;
  final String query;
  final String category;
  final int? minCents;
  final int? maxCents;
  final DateTime lastSeenAt;

  const SavedSearch({
    required this.id,
    this.query = '',
    this.category = '',
    this.minCents,
    this.maxCents,
    required this.lastSeenAt,
  });

  /// What the chip says: the words if any, else the category, else the
  /// price bounds — a search the store accepted is always one of the three.
  String get label {
    if (query.isNotEmpty) return query;
    if (category.isNotEmpty) return category;
    return [
      if (minCents != null) 'from \$${dollars(minCents!)}',
      if (maxCents != null) 'to \$${dollars(maxCents!)}',
    ].join(' ');
  }

  /// Cents as the text a price field accepts back ('90', '12.50') — also
  /// how re-applying a saved search refills the min/max boxes.
  static String dollars(int cents) => cents % 100 == 0
      ? '${cents ~/ 100}'
      : (cents / 100).toStringAsFixed(2);

  SavedSearch seenNow() => SavedSearch(
        id: id,
        query: query,
        category: category,
        minCents: minCents,
        maxCents: maxCents,
        lastSeenAt: DateTime.now(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'q': query,
        'cat': category,
        if (minCents != null) 'min': minCents,
        if (maxCents != null) 'max': maxCents,
        'seen': lastSeenAt.toIso8601String(),
      };

  factory SavedSearch.fromJson(Map<String, dynamic> json) => SavedSearch(
        id: json['id'] as String? ?? '',
        query: json['q'] as String? ?? '',
        category: json['cat'] as String? ?? '',
        minCents: (json['min'] as num?)?.toInt(),
        maxCents: (json['max'] as num?)?.toInt(),
        lastSeenAt: DateTime.tryParse(json['seen'] as String? ?? '') ??
            DateTime.now(),
      );
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
