import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../util/haptics.dart';

/// The row of actions under a post, for BOTH timelines.
///
/// There were two of these. The public feed spread four evenly across the
/// post's width; a server feed put three inside a 240-point box, then a
/// bookmark, then a share, all bunched to the left — so the same gesture sat
/// in a different place, at a different size, depending which of the two
/// timelines you were looking at. Unifying them is what this widget is for,
/// and both feeds still draw the identical row.
///
/// **Small, and gathered at the bottom LEFT (2026-08-14, the owner's call).**
/// This reverses the "evenly spread" note that used to sit here, which
/// argued the spread put every target under a thumb rather than crowding
/// them into one corner. That reasoning is not wrong, it just lost: spread
/// across a full-width card the icons read as the loudest thing on the post,
/// and on a wide screen a reply button ended up a long way from the words it
/// answers. Do not "restore" the spread.
///
/// **The order is LIKE · COMMENT · REPOST** (2026-08-14, the owner's call,
/// correcting the order the three were first gathered in). Like leads: it is
/// the one people reach for most and the cheapest to give, so it is the one
/// nearest the thumb; comment then repost is the rest in ascending order of
/// how much of their own name the reader is putting to it. Do not sort these
/// back into the reply-first order most timelines use.
///
/// Share stays at the RIGHT end. The three the owner named are what somebody
/// does to the post, and they are the group that moved; share sends it
/// somewhere else, which is a different kind of act and is where every
/// timeline of this shape keeps it.
///
/// **The floor: the row got visually smaller, not harder to hit.** Icon and
/// label shrank and the horizontal padding with them; the button's own
/// height did not move, and Material's padded tap target around it is left
/// alone. A first cut of this set `tapTargetSize: shrinkWrap`, which would
/// have taken the touchable area down with the glyph — the one change here
/// that would have made a real button worse to serve a look.
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
    this.viewCount = 0,
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

  /// How many people have opened this post — X's fourth number, and the one
  /// that makes the other three legible: two likes on a post nine hundred
  /// people saw is a different sentence from two likes on a post nine saw.
  ///
  /// A read-only TALLY, never a button. X opens post analytics from here;
  /// there is no such screen, and an author who wants the names already has
  /// "Viewed by" on their own post. A control that leads nowhere is worse
  /// than a number that admits it is only a number.
  ///
  /// Zero is not drawn, like every other count in this row — a brand-new
  /// post reading "0 views" is a fact nobody needs.
  final int viewCount;

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
        children: [
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
          if (viewCount > 0)
            FeedPostAction(
              // The bar chart is what X uses and what "views" reads as
              // everywhere else; a plain eye is the ghost/seen icon this app
              // already spends on read receipts.
              icon: Icons.bar_chart,
              count: viewCount,
              tooltip: viewCount == 1 ? '1 view' : '$viewCount views',
            ),
          // A post can SHOW what it was sparked, and can no longer BE
          // sparked. Money attached to one piece of content is a payment for
          // digital content, which is the shape Apple made Damus strip off
          // posts; tipping is a thing you do to a person, on their profile
          // or in a chat. The tally stays because it is history — hiding it
          // would erase money that really moved.
          if (onSpark != null || sparkCents > 0)
            FeedPostAction(
              icon: sparked ? Icons.bolt : Icons.bolt_outlined,
              count: sparkCount,
              // The total is the interesting number on a sparked post: three
              // sparks of a quarter and one of \$21 are different sentences.
              label: sparkCents > 0
                  ? '\$${sparkCents % 100 == 0 ? (sparkCents ~/ 100).toString() : (sparkCents / 100).toStringAsFixed(2)}'
                  : null,
              colour: sparked ? sparkColour : null,
              onTap: onSpark,
              tooltip: onSpark == null ? 'Sparked' : 'Spark',
            ),
          const Spacer(),
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
    this.onTap,
    required this.tooltip,
    this.colour,
    this.label,
  });

  final IconData icon;
  final int count;
  /// Null draws the action as a read-only tally rather than a button.
  final VoidCallback? onTap;
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
        icon: Icon(icon, size: 15, color: tint),
        label: Text(label ?? (count == 0 ? '' : '$count'),
            style: TextStyle(fontSize: 11.5, color: tint)),
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 5),
          // Left exactly as it was while the glyph shrank — see the note on
          // [FeedPostActions]. `VisualDensity.compact` trims 8 off this, so
          // the button really lays out 24 tall, not 32; Material's own
          // padded tap target is what puts a usable area around it, and it
          // is deliberately NOT set to shrinkWrap here.
          minimumSize: const Size(0, 32),
          visualDensity: VisualDensity.compact,
        ),
      ),
    );
  }
}
