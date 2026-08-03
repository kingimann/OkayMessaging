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
  });

  /// True when this points at a text channel rather than a feed thread.
  bool get isChannel => channelId.isNotEmpty;

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
      );
}
