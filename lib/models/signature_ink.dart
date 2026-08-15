import 'dart:ui' show Offset;

/// A drawn signature, as the strokes it is made of.
///
/// **This is a MARK, not a cryptographic signature.** It proves somebody drew
/// on a screen; it proves nothing about who they were, and anybody holding
/// the form can draw anything. The app has real signatures — every server
/// broadcast is signed with a per-sender key whose private half never leaves
/// the device — and calling this the same thing would be the most misleading
/// sentence in the product. Every surface that asks for one or shows one says
/// so, and a test pins that.
///
/// **Stored as strokes rather than an image**, for three reasons that all
/// matter here: a form answer is a `String` in a list that rides the ordinary
/// encrypted message path, so it has to be small; strokes redraw crisply at
/// any size, which a thumbnail-sized PNG does not; and normalised coordinates
/// mean the signature drawn on a 6.9" phone is the same signature on a 4.7"
/// one rather than a differently-cropped picture.
class SignatureInk {
  /// Points are 0..1 of the pad's own box, so nothing here depends on the
  /// size it was drawn at.
  final List<List<Offset>> strokes;

  const SignatureInk(this.strokes);

  static const SignatureInk empty = SignatureInk([]);

  bool get isEmpty {
    for (final s in strokes) {
      if (s.isNotEmpty) return false;
    }
    return true;
  }

  /// The cap that keeps one answer from growing without bound. A signature is
  /// a few seconds of drawing; past this the pad simply stops recording,
  /// which degrades the tail of a scribble rather than refusing the answer.
  static const int maxPoints = 600;

  /// Three decimals — about a third of a pixel on a 400-point pad, which is
  /// finer than a fingertip and half the bytes of the doubles' full form.
  static String _n(double v) => v.toStringAsFixed(3);

  /// `x,y x,y;x,y x,y` — points space-separated, strokes semicolon-separated.
  /// Chosen over JSON because this string is one entry in a list of answers
  /// that is itself already JSON, and nesting encodes every quote twice.
  String encode() => strokes
      .where((s) => s.isNotEmpty)
      .map((s) => s.map((p) => '${_n(p.dx)},${_n(p.dy)}').join(' '))
      .join(';');

  /// Reads back what [encode] wrote, and refuses to throw on anything else —
  /// this parses a string that arrived from another device, so a malformed
  /// one has to come back as an empty signature rather than take a screen
  /// down with it.
  static SignatureInk decode(String raw) {
    if (raw.trim().isEmpty) return empty;
    final out = <List<Offset>>[];
    for (final strokeText in raw.split(';')) {
      final points = <Offset>[];
      for (final pointText in strokeText.split(' ')) {
        if (pointText.isEmpty) continue;
        final parts = pointText.split(',');
        if (parts.length != 2) continue;
        final x = double.tryParse(parts[0]);
        final y = double.tryParse(parts[1]);
        if (x == null || y == null) continue;
        // Clamped rather than dropped: a point slightly outside the box is a
        // finger that ran off the edge, which is ordinary, and losing it
        // would put a gap in the middle of somebody's name.
        points.add(Offset(x.clamp(0.0, 1.0), y.clamp(0.0, 1.0)));
      }
      if (points.isNotEmpty) out.add(points);
    }
    return SignatureInk(out);
  }

  /// Whether a string looks like ink at all, for the places that have to tell
  /// a signature answer apart from an ordinary one.
  static bool looksLikeInk(String raw) => decode(raw).isEmpty == false;
}
