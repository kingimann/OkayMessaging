import 'package:flutter/material.dart';

import '../models/signature_ink.dart';
import '../theme/app_theme.dart';

/// Draws the strokes of a [SignatureInk] inside whatever box it is given.
///
/// Coordinates are 0..1, so the same signature renders at pad size while
/// somebody is drawing it and at thumbnail size in the responses list without
/// storing it twice or resampling anything.
class SignaturePainter extends CustomPainter {
  SignaturePainter({required this.ink, required this.colour, this.width = 2.4});

  final SignatureInk ink;
  final Color colour;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = colour
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    for (final stroke in ink.strokes) {
      if (stroke.isEmpty) continue;
      // A one-point stroke is a tap — a dot on an i, or a full stop. Drawn as
      // a dot rather than skipped, because a path of one point paints nothing
      // and the mark would silently lose it.
      if (stroke.length == 1) {
        final p = Offset(stroke.first.dx * size.width, stroke.first.dy * size.height);
        canvas.drawCircle(p, width / 2, paint..style = PaintingStyle.fill);
        paint.style = PaintingStyle.stroke;
        continue;
      }
      final path = Path()
        ..moveTo(stroke.first.dx * size.width, stroke.first.dy * size.height);
      for (final p in stroke.skip(1)) {
        path.lineTo(p.dx * size.width, p.dy * size.height);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant SignaturePainter old) =>
      old.ink != ink || old.colour != colour || old.width != width;
}

/// Sign here.
///
/// A `Listener` on raw pointer events rather than a `GestureDetector`: a pad
/// sits inside a scrolling form, and a pan recogniser would spend the first
/// few points of every stroke in the gesture arena arguing with the scroll
/// view — which shows up as a signature whose every stroke starts late. The
/// same reasoning the chat transcript's tap-off-to-dismiss already follows.
///
/// The honest limit is printed under the box, not buried in a doc comment:
/// this is a drawn mark, not proof of who drew it.
class SignaturePad extends StatefulWidget {
  const SignaturePad({
    super.key,
    required this.value,
    required this.onChanged,
    this.height = 160,
  });

  /// The encoded ink, so the pad is as stateless as every other answer
  /// control on the fill screen and re-entering the form redraws what was
  /// already signed.
  final String value;
  final ValueChanged<String> onChanged;
  final double height;

  @override
  State<SignaturePad> createState() => _SignaturePadState();
}

class _SignaturePadState extends State<SignaturePad> {
  late List<List<Offset>> _strokes = SignatureInk.decode(widget.value).strokes
      .map((s) => List<Offset>.of(s))
      .toList();

  @override
  void didUpdateWidget(SignaturePad old) {
    super.didUpdateWidget(old);
    // Only when the value changed from OUTSIDE — re-reading our own encode()
    // on every stroke would rebuild the list mid-drag and drop points.
    if (widget.value != old.value &&
        widget.value != SignatureInk(_strokes).encode()) {
      _strokes = SignatureInk.decode(widget.value)
          .strokes
          .map((s) => List<Offset>.of(s))
          .toList();
    }
  }

  int get _points {
    var n = 0;
    for (final s in _strokes) {
      n += s.length;
    }
    return n;
  }

  Offset? _at(Offset local, Size size) {
    if (size.width <= 0 || size.height <= 0) return null;
    return Offset(
      (local.dx / size.width).clamp(0.0, 1.0),
      (local.dy / size.height).clamp(0.0, 1.0),
    );
  }

  void _emit() => widget.onChanged(SignatureInk(_strokes).encode());

  @override
  Widget build(BuildContext context) {
    final ink = AppColors.accentOn(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final size = Size(constraints.maxWidth, widget.height);
            return Listener(
              // Opaque, not the default deferToChild: the pad's box is a
              // Container with a DECORATION, and a DecoratedBox does not hit
              // test itself — it defers to its child. With the empty pad that
              // child is the small centred "Sign here" label, so only those
              // few points accepted a stroke and the rest of the box was
              // dead. A test caught it; it would have been just as dead on a
              // phone.
              behavior: HitTestBehavior.opaque,
              onPointerDown: (e) {
                if (_points >= SignatureInk.maxPoints) return;
                final p = _at(e.localPosition, size);
                if (p == null) return;
                setState(() => _strokes.add([p]));
                _emit();
              },
              onPointerMove: (e) {
                if (_strokes.isEmpty) return;
                // Past the cap the pad stops RECORDING rather than refusing
                // the answer: the tail of a scribble degrades, which is far
                // better than a signature that cannot be given at all.
                if (_points >= SignatureInk.maxPoints) return;
                final p = _at(e.localPosition, size);
                if (p == null) return;
                setState(() => _strokes.last.add(p));
                _emit();
              },
              onPointerUp: (_) => _emit(),
              child: Container(
                width: size.width,
                height: size.height,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  border: Border.all(color: AppColors.subtle(context)
                      .withValues(alpha: 0.4)),
                ),
                child: CustomPaint(
                  painter:
                      SignaturePainter(ink: SignatureInk(_strokes), colour: ink),
                  child: _strokes.isEmpty
                      ? Center(
                          child: Text('Sign here',
                              style: TextStyle(
                                  color: AppColors.subtle(context),
                                  fontSize: 13.5)),
                        )
                      : const SizedBox.expand(),
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: Text(
                // The sentence that must not be edited out. A test pins it.
                'A drawn mark, not proof of who drew it.',
                style:
                    TextStyle(fontSize: 12, color: AppColors.subtle(context)),
              ),
            ),
            TextButton(
              onPressed: _strokes.isEmpty
                  ? null
                  : () {
                      setState(_strokes.clear);
                      _emit();
                    },
              child: const Text('Clear'),
            ),
          ],
        ),
      ],
    );
  }
}
