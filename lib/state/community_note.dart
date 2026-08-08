import 'package:flutter/foundation.dart';

/// A reader-written fact-check on a public-feed post — OkayMessenger's take on
/// X's Community Notes. Anyone with a (verified) account can propose a note
/// adding context to a post; everyone can rate a note helpful or not, and a
/// note that enough readers find helpful is SHOWN on the post itself.
///
/// **Honest about the algorithm.** X's real Community Notes uses a bridging
/// model that only surfaces a note when people who usually DISAGREE both rate
/// it helpful. That needs a cross-rater matrix this local-first app doesn't
/// collect. This is the simpler, honest version: a note shows on a plain
/// helpful-majority once enough people have weighed in. It's stated in the UI
/// as "Readers added context", not "verified true".
@immutable
class CommunityNote {
  final String id;
  final String postId;
  final String authorName;
  final String authorUsername;
  final bool authorVerified;
  final String body;
  final int helpfulCount;
  final int notHelpfulCount;
  final DateTime createdAt;

  /// This device's own rating: 1 helpful, -1 not helpful, 0 none.
  final int myRating;

  const CommunityNote({
    required this.id,
    required this.postId,
    this.authorName = '',
    this.authorUsername = '',
    this.authorVerified = false,
    required this.body,
    this.helpfulCount = 0,
    this.notHelpfulCount = 0,
    required this.createdAt,
    this.myRating = 0,
  });

  /// How many people rated this note at all.
  int get totalRatings => helpfulCount + notHelpfulCount;

  /// The share of raters who found it helpful (0 when nobody has rated).
  double get helpfulRatio =>
      totalRatings == 0 ? 0 : helpfulCount / totalRatings;

  /// A note needs at least this many ratings before it can show — one or two
  /// helpful taps is not consensus.
  static const minRatingsToShow = 5;

  /// ...and this share of them must be helpful.
  static const helpfulRatioToShow = 0.6;

  /// Whether this note has earned its place ON the post.
  bool get isShown =>
      totalRatings >= minRatingsToShow && helpfulRatio >= helpfulRatioToShow;

  /// The single note to display on a post: the shown note with the most
  /// helpful ratings, or null when none has reached consensus yet. Pure.
  static CommunityNote? topShown(Iterable<CommunityNote> notes) {
    CommunityNote? best;
    for (final n in notes) {
      if (!n.isShown) continue;
      if (best == null ||
          n.helpfulCount > best.helpfulCount ||
          (n.helpfulCount == best.helpfulCount &&
              n.createdAt.isAfter(best.createdAt))) {
        best = n;
      }
    }
    return best;
  }

  /// Notes ordered for the management screen: still-being-rated proposals
  /// first by how close they are to showing, then newest. Pure.
  static List<CommunityNote> ranked(Iterable<CommunityNote> notes) {
    final list = notes.toList()
      ..sort((a, b) {
        if (a.isShown != b.isShown) return a.isShown ? -1 : 1;
        final byHelpful = b.helpfulCount.compareTo(a.helpfulCount);
        if (byHelpful != 0) return byHelpful;
        return b.createdAt.compareTo(a.createdAt);
      });
    return list;
  }

  CommunityNote copyWith({
    int? helpfulCount,
    int? notHelpfulCount,
    int? myRating,
  }) =>
      CommunityNote(
        id: id,
        postId: postId,
        authorName: authorName,
        authorUsername: authorUsername,
        authorVerified: authorVerified,
        body: body,
        helpfulCount: helpfulCount ?? this.helpfulCount,
        notHelpfulCount: notHelpfulCount ?? this.notHelpfulCount,
        createdAt: createdAt,
        myRating: myRating ?? this.myRating,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'post_id': postId,
        'author_name': authorName,
        'author_username': authorUsername,
        'author_verified': authorVerified,
        'body': body,
        'helpful_count': helpfulCount,
        'not_helpful_count': notHelpfulCount,
        'created_at': createdAt.toIso8601String(),
        'my_rating': myRating,
      };

  factory CommunityNote.fromJson(Map<String, dynamic> j) => CommunityNote(
        id: j['id'] as String,
        postId: (j['post_id'] ?? '') as String,
        authorName: (j['author_name'] ?? '') as String,
        authorUsername: (j['author_username'] ?? '') as String,
        authorVerified: (j['author_verified'] ?? false) as bool,
        body: (j['body'] ?? '') as String,
        helpfulCount: (j['helpful_count'] as num?)?.toInt() ?? 0,
        notHelpfulCount: (j['not_helpful_count'] as num?)?.toInt() ?? 0,
        createdAt:
            DateTime.tryParse((j['created_at'] ?? '') as String) ?? DateTime(2000),
        myRating: (j['my_rating'] as num?)?.toInt() ?? 0,
      );
}
