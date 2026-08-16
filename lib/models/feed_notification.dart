/// The kind of interaction that involves you.
enum FeedNotificationType {
  reply,
  mention,
  repost,
  like,

  /// Someone sent real money pinned to your post (the preview carries the
  /// amount). The payment itself moved over Stripe before this existed.
  spark,

  /// Someone @mentioned you in a server's text channel (not the feed).
  channelMention,

  /// Someone followed you on the public feed. The one notification every
  /// social app has and this one had none of — and unlike the others it
  /// points at a PERSON rather than a post, so [threadPostId] is empty and
  /// [actorUsername] is what a tap opens.
  follow,

  /// Someone reviewed a marketplace listing you sold. Checked ahead of
  /// [reply] in classification — a review's parentId also points at your
  /// post, but "reviewed your listing" is a truer sentence than "replied to
  /// you".
  review,
}

/// Which surface a notification points at. The three live in different
/// stores and open in different screens, and nothing about the notification
/// itself distinguishes them.
///
/// An enum rather than the bool this started as: `publicFeed` alone was
/// right for two surfaces and would have grown a second bool for the forum,
/// then a third — two mutually exclusive booleans being the shape that
/// eventually lets both be true at once.
enum FeedNotificationSource {
  /// A server's own feed, or one of its channels — the original, and what
  /// every notification was before the public timeline learned to alert.
  serverFeed,

  /// The public newsfeed.
  publicFeed,

  /// The public forum — its own tables, its own board, its own screen.
  publicForum,
}

/// A record that another member interacted with you in a server feed — they
/// replied to your post, @mentioned you, or reposted you. Shown in the
/// Notifications tab and tappable to open the relevant thread.
class FeedNotification {
  /// The interacting post's id (the reply, the mentioning post, or the
  /// repost entry) — doubles as the dedup key.
  final String id;
  final FeedNotificationType type;
  final String communityId;
  final String actorName;
  final String actorUsername;
  final DateTime time;

  /// The thread to open: the reply/mention itself, or the reposted original.
  final String threadPostId;

  /// A short preview of what they said (empty for a repost).
  final String preview;
  final bool seen;

  /// For [FeedNotificationType.channelMention]: which channel to open, and its
  /// name for the "#general" label. Empty for feed notifications.
  final String channelId;
  final String channelName;

  /// Which surface [threadPostId] belongs to.
  ///
  /// Explicit rather than inferred from an empty [communityId], which looks
  /// like it would do the job and does not: a marketplace listing is global,
  /// so a review notification carries an empty community id while pointing at
  /// a server-feed post.
  final FeedNotificationSource source;

  const FeedNotification({
    required this.id,
    required this.type,
    required this.communityId,
    required this.actorName,
    required this.actorUsername,
    required this.time,
    required this.threadPostId,
    this.preview = '',
    this.seen = false,
    this.channelId = '',
    this.channelName = '',
    this.source = FeedNotificationSource.serverFeed,
  });

  /// True when this points at a text channel rather than a feed thread.
  bool get isChannel => channelId.isNotEmpty;

  /// True when it points at the public newsfeed.
  bool get publicFeed => source == FeedNotificationSource.publicFeed;

  /// True when it points at the public forum.
  bool get publicForum => source == FeedNotificationSource.publicForum;

  FeedNotification copyWith({bool? seen}) => FeedNotification(
        id: id,
        type: type,
        communityId: communityId,
        actorName: actorName,
        actorUsername: actorUsername,
        time: time,
        threadPostId: threadPostId,
        preview: preview,
        seen: seen ?? this.seen,
        channelId: channelId,
        channelName: channelName,
        source: source,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.name,
        'communityId': communityId,
        'actorName': actorName,
        'actorUsername': actorUsername,
        'time': time.toIso8601String(),
        'threadPostId': threadPostId,
        'preview': preview,
        'seen': seen,
        if (channelId.isNotEmpty) 'channelId': channelId,
        if (channelName.isNotEmpty) 'channelName': channelName,
        if (source != FeedNotificationSource.serverFeed) 'source': source.name,
      };

  factory FeedNotification.fromJson(Map<String, dynamic> j) =>
      FeedNotification(
        id: j['id'] as String,
        type: FeedNotificationType.values.firstWhere(
            (t) => t.name == j['type'],
            orElse: () => FeedNotificationType.mention),
        communityId: j['communityId'] as String? ?? '',
        actorName: j['actorName'] as String? ?? '',
        actorUsername: j['actorUsername'] as String? ?? '',
        time: DateTime.tryParse(j['time'] as String? ?? '') ?? DateTime(2024),
        threadPostId: j['threadPostId'] as String? ?? '',
        preview: j['preview'] as String? ?? '',
        seen: j['seen'] as bool? ?? false,
        channelId: j['channelId'] as String? ?? '',
        channelName: j['channelName'] as String? ?? '',
        source: FeedNotificationSource.values
                .where((v) => v.name == j['source'])
                .firstOrNull ??
            // Written before this was an enum; a stored alert must not
            // change which screen it opens because the app was updated.
            (j['publicFeed'] as bool? ?? false
                ? FeedNotificationSource.publicFeed
                : FeedNotificationSource.serverFeed),
      );
}
