import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../util/haptics.dart';

/// The row of actions under a post, for BOTH timelines.
///
/// There were two of these. The public feed spread four evenly across the
/// post's width; a server feed put three inside a 240-point box, then a
/// bookmark, then a share, all bunched to the left — so the same gesture sat
/// in a different place, at a different size, depending which of the two
/// timelines you were looking at.
///
/// Evenly spread is the one that survives: it is the shape a timeline like
/// this has, and it puts every target under a thumb instead of crowding them
/// into one corner. The last one stops short of the edge rather than touching
/// it.
class FeedPostActions extends StatelessWidget {
  const FeedPostActions({
    super.key,
    required this.replyCount,
    required this.repostCount,
    required this.likeCount,
    required this.liked,
    required this.reposted,
    required this.onReply,
    required this.onRepost,
    required this.onLike,
    required this.onShare,
    this.sparkCount = 0,
    this.sparkCents = 0,
    this.sparked = false,
    this.onSpark,
  });

  final int replyCount;
  final int repostCount;
  final int likeCount;
  final bool liked;
  final bool reposted;

  final VoidCallback onReply;
  final VoidCallback onRepost;
  final VoidCallback onLike;
  final VoidCallback onShare;

  /// Sparks (real-money tips on the post). The bolt only appears where sparking
  /// is actually possible — [onSpark] null hides it, so the public feed and
  /// your own posts stay a four-action row.
  final int sparkCount;
  final int sparkCents;
  final bool sparked;
  final VoidCallback? onSpark;

  /// The green a repost is, and the pink a liked heart is, everywhere else —
  /// so the gesture reads without being learned.
  static const Color repostColour = Color(0xFF00BA7C);
  static const Color likeColour = Color(0xFFF91880);

  /// Bolt amber — the colour this gesture wears in Damus/Nostr, where it
  /// is called a "zap".
  static const Color sparkColour = Color(0xFFF7931A);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          FeedPostAction(
            icon: Icons.chat_bubble_outline,
            count: replyCount,
            onTap: onReply,
            tooltip: 'Reply',
          ),
          FeedPostAction(
            icon: Icons.repeat,
            count: repostCount,
            colour: reposted ? repostColour : null,
            onTap: onRepost,
            tooltip: 'Repost',
          ),
          FeedPostAction(
            icon: liked ? Icons.favorite : Icons.favorite_border,
            count: likeCount,
            colour: liked ? likeColour : null,
            // A like lands under the thumb as well as on the screen; reply
            // and share just open UI, so they stay silent.
            onTap: () {
              Haptics.tap();
              onLike();
            },
            tooltip: 'Like',
          ),
          if (onSpark != null)
            FeedPostAction(
              icon: sparked ? Icons.bolt : Icons.bolt_outlined,
              count: sparkCount,
              // The total is the interesting number on a sparked post: three
              // sparks of a quarter and one of \$21 are different sentences.
              label: sparkCents > 0
                  ? '\$${sparkCents % 100 == 0 ? (sparkCents ~/ 100).toString() : (sparkCents / 100).toStringAsFixed(2)}'
                  : null,
              colour: sparked ? sparkColour : null,
              onTap: onSpark!,
              tooltip: 'Spark',
            ),
          FeedPostAction(
            icon: Icons.ios_share,
            count: 0,
            onTap: onShare,
            tooltip: 'Copy text',
          ),
        ],
      ),
    );
  }
}

/// One action: an icon, and its count when there is one to show.
///
/// A zero is not drawn. "0 replies" is a fact nobody needs and four of them
/// under every post is a row of noise.
class FeedPostAction extends StatelessWidget {
  const FeedPostAction({
    super.key,
    required this.icon,
    required this.count,
    required this.onTap,
    required this.tooltip,
    this.colour,
    this.label,
  });

  final IconData icon;
  final int count;
  final VoidCallback onTap;
  final String tooltip;
  final Color? colour;

  /// Overrides the count as the drawn text (e.g. a spark total in dollars).
  final String? label;

  @override
  Widget build(BuildContext context) {
    final tint = colour ?? AppColors.subtle(context);
    return Tooltip(
      message: tooltip,
      child: TextButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 17, color: tint),
        label: Text(label ?? (count == 0 ? '' : '$count'),
            style: TextStyle(fontSize: 12.5, color: tint)),
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          minimumSize: const Size(0, 32),
          visualDensity: VisualDensity.compact,
        ),
      ),
    );
  }
}
