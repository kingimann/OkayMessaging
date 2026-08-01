import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A long post, folded down to a readable height with a way to open it.
///
/// Neither timeline truncated anything, so one person pasting an essay took
/// the whole screen and everything under it went unread. This is the same on
/// both feeds by construction — it is one widget, and the two of them render
/// their bodies through different tag-highlighting widgets that would
/// otherwise have drifted apart.
///
/// The decision is made by MEASURING, not by counting characters: a post of
/// short lines and a post of one long paragraph reach the fold at completely
/// different lengths, and a character count gets both wrong.
class CollapsibleText extends StatefulWidget {
  const CollapsibleText({
    super.key,
    required this.text,
    required this.style,
    required this.builder,
    this.maxLines = 10,
  });

  /// The plain text, used to measure. What is actually drawn comes from
  /// [builder], which is where each feed does its own #tag and @mention work.
  final String text;

  /// The base style the measurement uses. Must match what [builder] draws in,
  /// or the fold lands somewhere other than where it was measured.
  final TextStyle style;

  /// Draws the body, clipped to the line count it is given — null means show
  /// all of it.
  final Widget Function(BuildContext context, int? maxLines) builder;

  /// How much shows before folding. Ten lines is about a third of a phone,
  /// which is enough to know whether you want the rest.
  final int maxLines;

  @override
  State<CollapsibleText> createState() => _CollapsibleTextState();
}

class _CollapsibleTextState extends State<CollapsibleText> {
  bool _expanded = false;

  @override
  void didUpdateWidget(CollapsibleText old) {
    super.didUpdateWidget(old);
    // A recycled row showing a different post starts folded again — a list
    // reuses its widgets, so without this an expanded row stays expanded for
    // whatever scrolls into it.
    if (old.text != widget.text) _expanded = false;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: widget.style),
          maxLines: widget.maxLines,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: box.maxWidth);
        final overflows = painter.didExceedMaxLines;
        painter.dispose();

        if (!overflows) return widget.builder(context, null);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            widget.builder(context, _expanded ? null : widget.maxLines),
            // A row of its own rather than a link tacked onto the end of the
            // text: tapping the post opens the thread, and a target inside
            // the paragraph would be a coin toss between the two.
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: InkWell(
                onTap: () => setState(() => _expanded = !_expanded),
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    _expanded ? 'Show less' : 'Show more',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.accentOn(context),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
