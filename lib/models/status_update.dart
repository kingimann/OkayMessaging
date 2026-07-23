/// A single ephemeral status update (a "story"): a short line of text on a
/// colored background that expires after 24 hours.
class StatusUpdate {
  final String id;
  final String authorId;
  final String authorName;

  /// Avatar color hex for the author (so the ring/avatar can render).
  final String avatarColor;
  final String text;

  /// Background color hex for the status card.
  final String bgColor;
  final DateTime time;

  const StatusUpdate({
    required this.id,
    required this.authorId,
    required this.authorName,
    required this.avatarColor,
    required this.text,
    required this.bgColor,
    required this.time,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'authorId': authorId,
        'authorName': authorName,
        'avatarColor': avatarColor,
        'text': text,
        'bgColor': bgColor,
        'time': time.toIso8601String(),
      };

  factory StatusUpdate.fromJson(Map<String, dynamic> j) => StatusUpdate(
        id: j['id'] as String,
        authorId: j['authorId'] as String? ?? '',
        authorName: j['authorName'] as String? ?? '',
        avatarColor: j['avatarColor'] as String? ?? '#7A5CFF',
        text: j['text'] as String? ?? '',
        bgColor: j['bgColor'] as String? ?? '#7A5CFF',
        time: DateTime.tryParse(j['time'] as String? ?? '') ?? DateTime(2024),
      );
}
