import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Message body text that turns URLs into tappable links. Tapping a link
/// copies it and shows a brief confirmation (this UI demo has no browser to
/// hand off to). Owns its [TapGestureRecognizer]s and disposes them.
class LinkableText extends StatefulWidget {
  final String text;
  final Color textColor;
  final Color linkColor;

  const LinkableText({
    super.key,
    required this.text,
    required this.textColor,
    required this.linkColor,
  });

  /// Matches http(s):// URLs and bare www. links.
  static final RegExp urlPattern = RegExp(
    r'((https?:\/\/|www\.)[^\s]+)',
    caseSensitive: false,
  );

  static bool hasLink(String text) => urlPattern.hasMatch(text);

  @override
  State<LinkableText> createState() => _LinkableTextState();
}

class _LinkableTextState extends State<LinkableText> {
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  void _openLink(String url) {
    Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Link copied: $url')),
    );
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
        spans.add(TextSpan(text: widget.text.substring(index, match.start)));
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
      spans.add(TextSpan(text: widget.text.substring(index)));
    }

    return Text.rich(
      TextSpan(children: spans),
      style: TextStyle(color: widget.textColor, fontSize: 15.5, height: 1.3),
    );
  }
}
