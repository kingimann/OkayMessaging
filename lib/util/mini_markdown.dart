/// A deliberately tiny Markdown reader for Okay AI replies — just enough to
/// make ANSWERS and CODE readable, without pulling in a whole rendering
/// package. It understands three things, because that is what the assistant
/// actually produces:
///
///  * fenced code blocks (``` … ```), so code is monospaced and copyable;
///  * inline `code`;
///  * **bold**.
///
/// Everything else is passed through as plain text. Pure and deterministic, so
/// the parsing is unit-tested rather than eyeballed.
library;

/// One block of a reply: a paragraph of text, or a fenced code block.
class MdBlock {
  final bool isCode;
  final String text;

  /// The language tag after the opening fence (```dart), or '' — code only.
  final String language;

  const MdBlock.text(this.text)
      : isCode = false,
        language = '';
  const MdBlock.code(this.text, this.language) : isCode = true;
}

/// A run of inline text with its style flags.
class MdSpan {
  final String text;
  final bool bold;
  final bool code;
  const MdSpan(this.text, {this.bold = false, this.code = false});
}

class MiniMarkdown {
  MiniMarkdown._();

  /// Splits [src] into text and fenced-code blocks. A fence is a line that
  /// starts with ``` (optionally followed by a language). An unclosed fence
  /// runs to the end, so a reply that is cut off mid-code still renders as
  /// code rather than as a wall of prose.
  static List<MdBlock> blocks(String src) {
    final lines = src.split('\n');
    final out = <MdBlock>[];
    final buffer = <String>[];
    var inCode = false;
    var language = '';
    final code = <String>[];

    void flushText() {
      if (buffer.isEmpty) return;
      final text = buffer.join('\n').trim();
      if (text.isNotEmpty) out.add(MdBlock.text(text));
      buffer.clear();
    }

    void flushCode() {
      out.add(MdBlock.code(code.join('\n'), language));
      code.clear();
      language = '';
    }

    for (final line in lines) {
      final trimmed = line.trimLeft();
      if (trimmed.startsWith('```')) {
        if (inCode) {
          flushCode();
          inCode = false;
        } else {
          flushText();
          inCode = true;
          language = trimmed.substring(3).trim();
        }
        continue;
      }
      (inCode ? code : buffer).add(line);
    }
    if (inCode) {
      flushCode();
    } else {
      flushText();
    }
    return out;
  }

  /// Parses inline `code` and **bold** within a text block into styled runs.
  /// Unbalanced markers are treated as literal text.
  static List<MdSpan> inline(String src) {
    final spans = <MdSpan>[];
    final buffer = StringBuffer();

    void flush({bool bold = false, bool code = false}) {
      if (buffer.isEmpty) return;
      spans.add(MdSpan(buffer.toString(), bold: bold, code: code));
      buffer.clear();
    }

    var i = 0;
    while (i < src.length) {
      // Inline code: `…`
      if (src[i] == '`') {
        final end = src.indexOf('`', i + 1);
        if (end > i) {
          flush();
          spans.add(MdSpan(src.substring(i + 1, end), code: true));
          i = end + 1;
          continue;
        }
      }
      // Bold: **…**
      if (src.startsWith('**', i)) {
        final end = src.indexOf('**', i + 2);
        if (end > i) {
          flush();
          spans.add(MdSpan(src.substring(i + 2, end), bold: true));
          i = end + 2;
          continue;
        }
      }
      buffer.write(src[i]);
      i++;
    }
    flush();
    return spans;
  }
}
