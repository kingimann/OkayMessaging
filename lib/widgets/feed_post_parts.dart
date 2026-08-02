import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models/user.dart';
import '../screens/in_app_web_screen.dart';
import '../state/chat_store.dart';
import '../theme/app_theme.dart';
import '../utils/date_formatter.dart';
import 'collapsible_text.dart';
import 'user_avatar.dart';
import 'verified_badge.dart';

/// The parts a post is drawn from, for BOTH timelines.
///
/// There were two of everything. The public newsfeed and a server's feed show
/// the same thing — somebody's name, their handle, how long ago, a body with
/// tags and mentions in it, a picture, a row of actions — and each had its own
/// implementation, so the two drifted: different avatars for the same person,
/// a name that fit on one and truncated on the other, "40d" against "22 Jun",
/// links live in one and dead in the other, a body at 15pt beside one at
/// 15.5pt.
///
/// [FeedPostActions] was already shared for the row underneath. This is the
/// rest of it. Each feed still owns its own data, its own menus and its own
/// navigation — what it no longer owns is how a post LOOKS.
///
/// The numbers below are the shape both feeds have. Change them here and both
/// change; that is the point.
class FeedPostMetrics {
  FeedPostMetrics._();

  /// Around a whole post. The right side is tighter than the left because the
  /// "more" button lives there and has its own padding.
  static const EdgeInsets tilePadding = EdgeInsets.fromLTRB(14, 12, 8, 6);

  /// Between the avatar column and the post.
  static const double gutter = 12;

  static const double avatarRadius = 20;

  /// Body text. The line height matters more than the size: at 1.0 a
  /// three-line post reads as a block.
  static const TextStyle body = TextStyle(fontSize: 15, height: 1.35);

  /// The post a thread screen is about, set larger — the one visual cue
  /// that says "this is the post, those below are the replies".
  static const TextStyle focusedBody = TextStyle(fontSize: 18.5, height: 1.4);

  /// Corner rounding on an attached picture.
  static const double imageRadius = 12;
}

/// The colour behind somebody's avatar, derived from their handle.
///
/// Deterministic on purpose: a profile that looked different every time it
/// opened would read as a different profile.
Color feedHandleSeed(String username, ColorScheme scheme) {
  if (username.isEmpty) return scheme.primary;
  var hash = 0;
  for (final unit in username.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  return HSLColor.fromAHSL(1, (hash % 360).toDouble(), 0.45, 0.42).toColor();
}

/// The account behind a handle, when this device happens to know it: you, or
/// somebody there is a chat with.
///
/// WHY IT MATTERS. Everywhere else in this app a person is drawn by
/// [UserAvatar], with the colour they picked and the emoji they set. A feed
/// that draws its own circle from a hash of the handle makes somebody's own
/// face on the timeline a different colour from their face in chats, in calls
/// and on the contact list. One person looked like two.
///
/// Nobody else can be resolved, and that is not a gap to paper over: a
/// stranger on a public feed is a handle and a name, and a generated circle is
/// the honest way to draw one.
AppUser? knownUserFor(String username) {
  final handle = username.trim().toLowerCase();
  if (handle.isEmpty) return null;
  final me = AppState.profile.value;
  if (me.username.toLowerCase() == handle) return me;
  for (final chat in ChatStore.instance.chats) {
    if (chat.contact.username.toLowerCase() == handle) return chat.contact;
  }
  return null;
}

/// The colour behind a handle: the one they picked when this device knows
/// them, and a stable generated one otherwise, so the same person is the same
/// colour everywhere they appear.
Color profileAccentFor(String username, ColorScheme scheme) {
  final known = knownUserFor(username);
  if (known != null) {
    var hex = known.avatarColor.replaceFirst('#', '');
    if (hex.length == 6) hex = 'FF$hex';
    final value = int.tryParse(hex, radix: 16);
    if (value != null) return Color(value);
  }
  return feedHandleSeed(username, scheme);
}

/// One person's face on a timeline.
class FeedAvatar extends StatelessWidget {
  const FeedAvatar({
    super.key,
    required this.username,
    required this.name,
    this.radius = FeedPostMetrics.avatarRadius,
    this.onTap,
  });

  final String username;
  final String name;
  final double radius;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final known = knownUserFor(username);
    final source = name.trim().isEmpty ? username : name.trim();
    final initial = (source.isEmpty ? '?' : source[0]).toUpperCase();
    final avatar = known != null
        ? UserAvatar(user: known, radius: radius)
        : CircleAvatar(
            radius: radius,
            backgroundColor:
                profileAccentFor(username, scheme).withValues(alpha: 0.22),
            child: Text(initial,
                style: TextStyle(
                    fontSize: radius * 0.75, fontWeight: FontWeight.w700)),
          );
    if (onTap == null) return avatar;
    return GestureDetector(onTap: onTap, child: avatar);
  }
}

/// The line above a post: who wrote it, when, and the way into its menu.
///
/// The name is given the room it needs and the handle gives way first —
/// truncating "Ada Lovelace" to "Ada Lovel…" so that "@ada" can be shown in
/// full has it exactly backwards.
class FeedPostHeader extends StatelessWidget {
  const FeedPostHeader({
    super.key,
    required this.name,
    required this.username,
    required this.time,
    this.verified = false,
    this.edited = false,
    this.pinned = false,
    this.onAuthor,
    this.onMore,
  });

  final String name;
  final String username;
  final DateTime time;
  final bool verified;
  final bool edited;

  /// Servers can pin a post to the top of their feed. Public posts cannot, so
  /// this is simply never true there.
  final bool pinned;

  final VoidCallback? onAuthor;
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    final subtle = AppColors.subtle(context);
    final shown = name.trim().isEmpty ? '@$username' : name;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (pinned)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Row(
              children: [
                Icon(Icons.push_pin, size: 12, color: subtle),
                const SizedBox(width: 4),
                Text('Pinned',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: subtle)),
              ],
            ),
          ),
        Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: GestureDetector(
                      onTap: onAuthor,
                      child: Text(shown,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              const TextStyle(fontWeight: FontWeight.w700)),
                    ),
                  ),
                  if (verified) ...[
                    const SizedBox(width: 4),
                    const VerifiedBadge(size: 14),
                  ],
                  if (username.isNotEmpty && name.trim().isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text('@$username',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12.5, color: subtle)),
                    ),
                  ],
                  const SizedBox(width: 6),
                  Text(
                      '· ${DateFormatter.postAge(time)}'
                      '${edited ? ' · edited' : ''}',
                      style: TextStyle(fontSize: 12, color: subtle)),
                ],
              ),
            ),
            if (onMore != null)
              GestureDetector(
                onTap: onMore,
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.only(left: 8, bottom: 2),
                  child: Icon(Icons.more_horiz, size: 17, color: subtle),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// A post's words, with its #tags, @mentions and links live.
///
/// The link half is why this is one widget rather than two similar ones: a
/// pasted URL was tappable on a server feed and dead text on the public one,
/// and nobody would have found that by reading either file.
class FeedBodyText extends StatefulWidget {
  const FeedBodyText({
    super.key,
    required this.text,
    this.collapse = true,
    this.focused = false,
    this.onTag,
    this.onMention,
  });

  final String text;

  /// Whether a long body folds to a "Show more". False where the post is the
  /// whole screen — a thread — because there is nothing under it to protect.
  final bool collapse;

  /// Larger type for the one post a thread screen is about, so the post and
  /// its replies stop reading as the same thing.
  final bool focused;

  /// Tapping `#something`, with the hash included.
  final ValueChanged<String>? onTag;

  /// Tapping `@somebody`, without the at.
  final ValueChanged<String>? onMention;

  @override
  State<FeedBodyText> createState() => _FeedBodyTextState();
}

class _FeedBodyTextState extends State<FeedBodyText> {
  /// Held so they can be disposed. A [TapGestureRecognizer] made in build and
  /// dropped on the next one leaks its subscription, once per span, on every
  /// rebuild of every post on screen.
  final List<TapGestureRecognizer> _recognizers = [];

  void _clear() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  TapGestureRecognizer? _recognizerFor(String token) {
    VoidCallback? action;
    if (token.startsWith('#') && widget.onTag != null) {
      action = () => widget.onTag!(token);
    } else if (token.startsWith('@') && widget.onMention != null) {
      action = () => widget.onMention!(token.substring(1));
    } else if (token.startsWith('http')) {
      // On one of the app's own screens, never handed to a browser. The
      // helper also refuses anything that isn't http(s), which matters here
      // because a post's text is whatever somebody typed.
      action = () => InAppWebScreen.open(context, token);
    }
    if (action == null) return null;
    final r = TapGestureRecognizer()..onTap = action;
    _recognizers.add(r);
    return r;
  }

  TextStyle get _base =>
      widget.focused ? FeedPostMetrics.focusedBody : FeedPostMetrics.body;

  @override
  Widget build(BuildContext context) {
    if (!widget.collapse) return _rich(context, null);
    return CollapsibleText(
      text: widget.text,
      style: _base,
      builder: _rich,
    );
  }

  Widget _rich(BuildContext context, int? maxLines) {
    _clear();
    final base = _base;
    final accent = base.copyWith(
        color: Theme.of(context).colorScheme.primary,
        fontWeight: FontWeight.w600);
    final pattern =
        RegExp(r'(@[A-Za-z0-9_.]+|#[A-Za-z0-9_]+|https?://\S+)');
    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in pattern.allMatches(widget.text)) {
      if (m.start > last) {
        spans.add(TextSpan(
            text: widget.text.substring(last, m.start), style: base));
      }
      final token = m.group(0)!;
      spans.add(TextSpan(
          text: token, style: accent, recognizer: _recognizerFor(token)));
      last = m.end;
    }
    if (last < widget.text.length) {
      spans.add(TextSpan(text: widget.text.substring(last), style: base));
    }
    return Text.rich(
      TextSpan(
          children: spans.isEmpty
              ? [TextSpan(text: widget.text, style: base)]
              : spans),
      maxLines: maxLines,
      overflow: maxLines == null ? TextOverflow.clip : TextOverflow.ellipsis,
    );
  }
}

/// "Somebody reposted", above the post they repeated.
///
/// A plain repeat has nothing of its own to say, so it is drawn as the
/// ORIGINAL post with a line above it naming who passed it on. Drawing it as
/// a post by the reposter with an empty body and the original in a quote box
/// — which the public timeline did — reads as somebody posting nothing.
///
/// Indented to the post's own text column, so the line belongs to the post
/// under it rather than floating at the edge of the screen.
class FeedRepostHeader extends StatelessWidget {
  const FeedRepostHeader({super.key, required this.by});

  /// Who passed it on, already resolved to a name or a handle.
  final String by;

  @override
  Widget build(BuildContext context) {
    final subtle = AppColors.subtle(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
          FeedPostMetrics.tilePadding.left +
              FeedPostMetrics.avatarRadius * 2 +
              FeedPostMetrics.gutter,
          8,
          16,
          0),
      child: Row(
        children: [
          Icon(Icons.repeat, size: 14, color: subtle),
          const SizedBox(width: 6),
          Flexible(
            child: Text('$by reposted',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: subtle)),
          ),
        ],
      ),
    );
  }
}

/// A picture attached to a post, full width and tappable.
///
/// [child] is the thumbnail, because the two feeds decode their images
/// differently — one carries data: URIs through ChatPhoto, the other fetches a
/// URL — and that is a real difference rather than drift. What they share is
/// the rounding and that tapping opens it.
class FeedPostImage extends StatelessWidget {
  const FeedPostImage({
    super.key,
    required this.child,
    this.onOpen,
  });

  final Widget child;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onOpen,
        child: ClipRRect(
          borderRadius:
              BorderRadius.circular(FeedPostMetrics.imageRadius),
          child: child,
        ),
      );
}

/// The quick reply pinned to the bottom of a thread.
///
/// A thread is the one screen where the next thing somebody does is almost
/// always "say something back", so the field is already there. The reply
/// button on a post still opens the full composer — that is for answering a
/// particular comment, and for anything longer than a line.
///
/// [onSend] returns whether it was accepted. A server's word filter can
/// refuse one, and a refusal must leave what was typed where it is.
class FeedReplyBar extends StatefulWidget {
  const FeedReplyBar({super.key, required this.handle, required this.onSend});

  /// Whose post is being answered, without the at.
  final String handle;

  final Future<bool> Function(String text) onSend;

  @override
  State<FeedReplyBar> createState() => _FeedReplyBarState();
}

class _FeedReplyBarState extends State<FeedReplyBar> {
  final TextEditingController _text = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _text.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    final ok = await widget.onSend(text);
    if (!mounted) return;
    setState(() => _sending = false);
    if (!ok) return;
    _text.clear();
    if (mounted) FocusScope.of(context).unfocus();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 12, 10),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _text,
                minLines: 1,
                maxLines: 3,
                textCapitalization: TextCapitalization.sentences,
                onSubmitted: (_) => _send(),
                decoration: InputDecoration(
                  hintText: widget.handle.isEmpty
                      ? 'Post your reply'
                      : 'Reply to @${widget.handle}',
                  filled: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 8),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              icon: const Icon(Icons.send, size: 18),
              tooltip: 'Send reply',
              onPressed: _sending ? null : _send,
            ),
          ],
        ),
      ),
    );
  }
}

/// A photo on its own, black background, pinch to zoom.
class FeedPhotoScreen extends StatelessWidget {
  const FeedPhotoScreen({super.key, required this.url, required this.by});

  final String url;
  final String by;

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: Text(by, style: const TextStyle(fontSize: 15)),
        ),
        body: Center(
          child: InteractiveViewer(
            maxScale: 5,
            child: Image.network(
              url,
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => const Text(
                  'That photo could not be loaded.',
                  style: TextStyle(color: Colors.white70)),
              loadingBuilder: (context, child, progress) => progress == null
                  ? child
                  : const CircularProgressIndicator(color: Colors.white),
            ),
          ),
        ),
      );
}

/// The tab row used by every timeline and by a profile: even columns, bold
/// label, short underline under the active one.
///
/// One widget so they cannot drift into looking like different apps — a
/// server feed drew its own three tabs, close enough to these to look like a
/// mistake rather than a choice.
class FeedTabStrip extends StatelessWidget {
  final List<String> labels;

  /// One glyph per label, or null to draw the words.
  ///
  /// The profile's four tabs are icons — four words across a phone leave
  /// "Servers" nearly touching its neighbours. The feed's filters stay as
  /// words: there are two of them, they have all the room they need, and
  /// "Following" is not a thing with an obvious picture.
  final List<IconData>? icons;

  final int active;
  final ValueChanged<int> onPick;
  const FeedTabStrip(
      {super.key,
      required this.labels,
      required this.active,
      required this.onPick,
      this.icons});

  /// The underline's own size, shared by the widget that draws it and the sums
  /// that place it.
  static const double _markWidth = 44;
  static const double _markHeight = 3;

  /// The travelling underline. Named so a test can ask where it is — there is
  /// exactly one, which is the property worth pinning: three marks that each
  /// appear and disappear can show two tabs as selected at once, and did.
  static const Key markKey = Key('feed_tab_mark');

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, box) {
        // Even columns, so where the mark belongs is arithmetic rather than
        // something to measure.
        final cell = box.maxWidth / labels.length;
        return Column(
          children: [
            Stack(
              children: [
                Row(
                  children: [
                    for (var i = 0; i < labels.length; i++)
                      Expanded(
                        // Named either way. An icon strip carries no words, so
                        // without this a screen reader announces four buttons
                        // called nothing — and "replies" and "posts" are two
                        // speech bubbles to anyone guessing.
                        child: Semantics(
                          label: labels[i],
                          selected: i == active,
                          button: true,
                          child: Tooltip(
                            message: labels[i],
                            child: InkWell(
                              onTap: () => onPick(i),
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                    4, 12, 4, 12 + _markHeight + 8),
                                child: Center(
                                  child: icons != null
                                      ? Icon(
                                          icons![i],
                                          size: 21,
                                          color: i == active
                                              ? scheme.onSurface
                                              : AppColors.subtle(context),
                                        )
                                      // The weight changes with the tab, so a
                                      // strip of words is laid out for the
                                      // bold one either way — columns that
                                      // shift as you tap read as the whole
                                      // row moving.
                                      : Text(
                                          labels[i],
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontWeight: i == active
                                                ? FontWeight.w700
                                                : FontWeight.w500,
                                            color: i == active
                                                ? scheme.onSurface
                                                : AppColors.subtle(context),
                                          ),
                                        ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                // ONE mark that travels, rather than one per tab appearing and
                // disappearing. It is the thing that says which tab you are on,
                // and watching it move is what tells you the tap landed.
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  bottom: 0,
                  left: cell * active + (cell - _markWidth) / 2,
                  child: Container(
                    key: markKey,
                    height: _markHeight,
                    width: _markWidth,
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ],
            ),
            const Divider(height: 1),
          ],
        );
      },
    );
  }
}


/// What a timeline is talking about, and whatever is currently narrowing it.
///
/// Trending shows only when nothing else is on: a strip of hashtags above an
/// already-filtered feed is a way to lose track of what you are looking at.
/// A filter you cannot see, meanwhile, is a feed that looks broken — so when
/// one is on, this is the chip that says so and takes it off again.
///
/// [tags] are bare, without the hash; this adds it.
class FeedTrendingBar extends StatelessWidget {
  const FeedTrendingBar({
    super.key,
    required this.tags,
    required this.tag,
    required this.onTag,
    this.query = '',
    this.onClearQuery,
  });

  final List<(String, int)> tags;

  /// The tag currently narrowing the feed, bare. Empty for none.
  final String tag;

  /// Picking one from the strip, bare.
  final ValueChanged<String> onTag;

  /// Free text currently narrowing the feed. Empty for none.
  final String query;
  final VoidCallback? onClearQuery;

  @override
  Widget build(BuildContext context) {
    if (tag.isNotEmpty || query.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
        child: Wrap(
          spacing: 8,
          children: [
            if (tag.isNotEmpty)
              InputChip(
                label: Text('#$tag'),
                onDeleted: () => onTag(''),
              ),
            if (query.isNotEmpty && onClearQuery != null)
              InputChip(
                label: Text('"$query"'),
                onDeleted: onClearQuery,
              ),
          ],
        ),
      );
    }
    if (tags.isEmpty) return const SizedBox.shrink();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      child: Row(
        children: [
          Text('TRENDING',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.6,
                  color: AppColors.subtle(context))),
          const SizedBox(width: 12),
          for (final (name, count) in tags) ...[
            GestureDetector(
              onTap: () => onTag(name),
              child: Text('#$name',
                  style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.primary)),
            ),
            const SizedBox(width: 4),
            Text('$count',
                style: TextStyle(
                    fontSize: 11.5, color: AppColors.subtle(context))),
            const SizedBox(width: 14),
          ],
        ],
      ),
    );
  }
}

/// The end of a timeline. One line, so both feeds stop the same way instead of
/// one of them simply running out of posts.
class FeedEndOfList extends StatelessWidget {
  const FeedEndOfList({super.key, this.label = 'That\'s everything.'});

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Text(label,
              style:
                  TextStyle(fontSize: 12.5, color: AppColors.subtle(context))),
        ),
      );
}
