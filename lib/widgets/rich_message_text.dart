import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import 'linkable_text.dart';

/// The inline styles supported in message text.
enum RunStyle { plain, bold, italic, strike, mono }

/// A parsed run of message text with the style it should render in.
class TextRun {
  final String text;
  final RunStyle style;
  const TextRun(this.text, this.style);
}

/// Message body text with WhatsApp-style inline formatting and tappable links.
///
/// Formatting markers: `*bold*`, `_italic_`, `~strikethrough~`, `` `mono` ``.
/// URLs are detected and rendered as tappable links (tapping copies the link).
class RichMessageText extends StatefulWidget {
  final String text;
  final Color textColor;
  final Color linkColor;

  const RichMessageText({
    super.key,
    required this.text,
    required this.textColor,
    required this.linkColor,
  });

  static final RegExp _format =
      RegExp(r'\*(.+?)\*|_(.+?)_|~(.+?)~|`(.+?)`');

  /// An @mention token: an "@" at a word boundary followed by a name word.
  static final RegExp mention = RegExp(r'(?<=^|\s)@\w+');

  /// Splits [text] into styled runs by the formatting markers. Pure — used by
  /// the widget and by tests.
  static List<TextRun> parse(String text) {
    final runs = <TextRun>[];
    var index = 0;
    for (final m in _format.allMatches(text)) {
      if (m.start > index) {
        runs.add(TextRun(text.substring(index, m.start), RunStyle.plain));
      }
      if (m.group(1) != null) {
        runs.add(TextRun(m.group(1)!, RunStyle.bold));
      } else if (m.group(2) != null) {
        runs.add(TextRun(m.group(2)!, RunStyle.italic));
      } else if (m.group(3) != null) {
        runs.add(TextRun(m.group(3)!, RunStyle.strike));
      } else {
        runs.add(TextRun(m.group(4)!, RunStyle.mono));
      }
      index = m.end;
    }
    if (index < text.length) {
      runs.add(TextRun(text.substring(index), RunStyle.plain));
    }
    return runs;
  }

  @override
  State<RichMessageText> createState() => _RichMessageTextState();
}

class _RichMessageTextState extends State<RichMessageText> {
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  TextStyle _styleFor(RunStyle style) {
    switch (style) {
      case RunStyle.plain:
        return const TextStyle();
      case RunStyle.bold:
        return const TextStyle(fontWeight: FontWeight.bold);
      case RunStyle.italic:
        return const TextStyle(fontStyle: FontStyle.italic);
      case RunStyle.strike:
        return const TextStyle(decoration: TextDecoration.lineThrough);
      case RunStyle.mono:
        return const TextStyle(fontFamily: 'monospace', fontSize: 14.5);
    }
  }

  void _openLink(String url) {
    Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Link copied: $url')),
    );
  }

  List<InlineSpan> _formattedSpans(String text) {
    final spans = <InlineSpan>[];
    for (final run in RichMessageText.parse(text)) {
      final base = _styleFor(run.style);
      final mentionStyle =
          base.merge(TextStyle(color: widget.linkColor, fontWeight: FontWeight.w600));
      var idx = 0;
      for (final m in RichMessageText.mention.allMatches(run.text)) {
        if (m.start > idx) {
          spans.add(TextSpan(text: run.text.substring(idx, m.start), style: base));
        }
        spans.add(TextSpan(text: m.group(0), style: mentionStyle));
        idx = m.end;
      }
      if (idx < run.text.length) {
        spans.add(TextSpan(text: run.text.substring(idx), style: base));
      }
    }
    return spans;
  }

  @override
  Widget build(BuildContext context) {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();

    final spans = <InlineSpan>[];
    var index = 0;
    for (final match in LinkableText.urlPattern.allMatches(widget.text)) {
      if (match.start > index) {
        spans.addAll(_formattedSpans(widget.text.substring(index, match.start)));
      }
      final url = match.group(0)!;
      final recognizer = TapGestureRecognizer()..onTap = () => _openLink(url);
      _recognizers.add(recognizer);
      spans.add(TextSpan(
        text: url,
        style: TextStyle(
          color: widget.linkColor,
          decoration: TextDecoration.underline,
          decorationColor: widget.linkColor,
        ),
        recognizer: recognizer,
      ));
      index = match.end;
    }
    if (index < widget.text.length) {
      spans.addAll(_formattedSpans(widget.text.substring(index)));
    }

    // Rebuild when the user changes their message-text-size preference.
    return ValueListenableBuilder<double>(
      valueListenable: AppState.messageTextScale,
      builder: (context, scale, _) => Text.rich(
        TextSpan(children: spans),
        textScaler: TextScaler.linear(scale),
        style:
            TextStyle(color: widget.textColor, fontSize: 16, height: 1.35),
      ),
    );
  }
}
