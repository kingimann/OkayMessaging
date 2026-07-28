/// The kind of feed interaction that mentions you.
enum FeedNotificationType { reply, mention, repost, like }

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
  });

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
      );
}
