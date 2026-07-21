import 'package:flutter/material.dart';

/// A short-lived heart that pops and floats up, shown when a message is
/// double-tapped. It self-animates and calls [onDone] when finished so the
/// hosting [OverlayEntry] can remove itself.
class HeartBurst extends StatefulWidget {
  final Offset position;
  final VoidCallback onDone;

  const HeartBurst({super.key, required this.position, required this.onDone});

  @override
  State<HeartBurst> createState() => _HeartBurstState();
}

class _HeartBurstState extends State<HeartBurst>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );

  late final Animation<double> _scale = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(begin: 0.0, end: 1.25)
          .chain(CurveTween(curve: Curves.easeOutBack)),
      weight: 45,
    ),
    TweenSequenceItem(tween: Tween(begin: 1.25, end: 1.0), weight: 15),
    TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.9), weight: 40),
  ]).animate(_controller);

  late final Animation<double> _opacity = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.0), weight: 20),
    TweenSequenceItem(tween: ConstantTween(1.0), weight: 40),
    TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.0), weight: 40),
  ]).animate(_controller);

  late final Animation<double> _rise =
      Tween<double>(begin: 0, end: -34).animate(
    CurvedAnimation(parent: _controller, curve: Curves.easeOut),
  );

  @override
  void initState() {
    super.initState();
    _controller.forward().whenComplete(widget.onDone);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Positioned(
          left: widget.position.dx - 22,
          top: widget.position.dy - 22 + _rise.value,
          child: Opacity(
            opacity: _opacity.value.clamp(0.0, 1.0),
            child: Transform.scale(
              scale: _scale.value,
              child: const Icon(
                Icons.favorite,
                color: Color(0xFFFF2D55),
                size: 44,
                shadows: [
                  Shadow(color: Colors.black26, blurRadius: 6),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
