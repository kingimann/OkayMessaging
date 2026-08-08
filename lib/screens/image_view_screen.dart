import 'package:flutter/material.dart';

import '../models/message.dart';
import '../utils/date_formatter.dart';
import '../widgets/chat_photo.dart';

/// A full-screen viewer for an image [Message] — photo or GIF — opened by
/// tapping a media bubble. Modelled on X's media viewer:
///
/// - **Swipe down to dismiss** — the image follows your finger and the black
///   backdrop fades as you drag; past a threshold (or a flick) it closes.
/// - **Tap to toggle chrome** — the bar and actions slide away so the image
///   owns the screen, and back on the next tap.
/// - **Double-tap to zoom** to the point you tapped, again to reset; pinch-zoom
///   and pan on top of that.
/// - **Like / react** are explicit buttons in the bottom bar (double-tap is the
///   zoom gesture here, as on X — the bubble in the timeline is where
///   double-tap-to-like lives). [onToggleLike] performs the ❤️ toggle,
///   [onPickReaction] opens the full emoji picker.
class ImageViewScreen extends StatefulWidget {
  final Message message;
  final String senderName;
  final bool liked;
  final VoidCallback? onToggleLike;
  final VoidCallback? onPickReaction;

  const ImageViewScreen({
    super.key,
    required this.message,
    required this.senderName,
    this.liked = false,
    this.onToggleLike,
    this.onPickReaction,
  });

  @override
  State<ImageViewScreen> createState() => _ImageViewScreenState();
}

class _ImageViewScreenState extends State<ImageViewScreen>
    with TickerProviderStateMixin {
  late bool _liked = widget.liked;
  final TransformationController _tc = TransformationController();

  /// Whether the top/bottom chrome is showing (tap toggles it).
  bool _chrome = true;

  /// True once the image is zoomed past 1× — turns the dismiss drag off and
  /// hands panning to the [InteractiveViewer].
  bool _zoomed = false;

  /// Live vertical offset of the swipe-to-dismiss drag.
  double _dragDy = 0;

  TapDownDetails? _doubleTapDetails;

  late final AnimationController _zoomAnim = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 220));
  Animation<Matrix4>? _zoomTween;

  late final AnimationController _burst = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 650));

  static const _gradients = [
    [Color(0xFF667EEA), Color(0xFF764BA2)],
    [Color(0xFFFF9A9E), Color(0xFFFAD0C4)],
    [Color(0xFF43CEA2), Color(0xFF185A9D)],
    [Color(0xFFF6D365), Color(0xFFFDA085)],
    [Color(0xFF30CFD0), Color(0xFF330867)],
    [Color(0xFFA8EDEA), Color(0xFFFED6E3)],
  ];

  @override
  void initState() {
    super.initState();
    _tc.addListener(() {
      final zoomed = _tc.value.getMaxScaleOnAxis() > 1.01;
      if (zoomed != _zoomed) setState(() => _zoomed = zoomed);
    });
    _zoomAnim.addListener(() {
      final t = _zoomTween;
      if (t != null) _tc.value = t.value;
    });
  }

  @override
  void dispose() {
    _zoomAnim.dispose();
    _burst.dispose();
    _tc.dispose();
    super.dispose();
  }

  Widget _placeholder(List<Color> colors) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ),
      ),
      child: const Center(
        child: Icon(Icons.image, color: Colors.white70, size: 96),
      ),
    );
  }

  void _animateTo(Matrix4 target) {
    _zoomTween = Matrix4Tween(begin: _tc.value, end: target)
        .animate(CurvedAnimation(parent: _zoomAnim, curve: Curves.easeOut));
    _zoomAnim.forward(from: 0);
  }

  void _handleDoubleTap() {
    if (_zoomed) {
      _animateTo(Matrix4.identity());
      return;
    }
    final pos = _doubleTapDetails?.localPosition ?? Offset.zero;
    const scale = 2.5;
    final target = Matrix4.identity()
      ..translateByDouble(
          -pos.dx * (scale - 1), -pos.dy * (scale - 1), 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
    _animateTo(target);
  }

  void _toggleLike() {
    final action = widget.onToggleLike;
    if (action == null) return;
    action();
    setState(() => _liked = !_liked);
    if (_liked) _burst.forward(from: 0);
  }

  void _onDragUpdate(DragUpdateDetails d) {
    setState(() => _dragDy += d.delta.dy);
  }

  void _onDragEnd(DragEndDetails d) {
    final v = d.primaryVelocity ?? 0;
    if (_dragDy.abs() > 130 || v.abs() > 700) {
      Navigator.of(context).pop();
    } else {
      setState(() => _dragDy = 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors =
        _gradients[widget.message.imageSeed % _gradients.length];
    final canReact = widget.onToggleLike != null;
    // The backdrop dims as the dismiss drag grows — the image lifting off a
    // fading black is the whole feel of the gesture.
    final dragFade = (1 - (_dragDy.abs() / 500)).clamp(0.0, 1.0);

    return Scaffold(
      backgroundColor: Colors.black.withValues(alpha: dragFade),
      extendBodyBehindAppBar: true,
      appBar: _chrome
          ? AppBar(
              backgroundColor: Colors.black.withValues(alpha: 0.25),
              foregroundColor: Colors.white,
              elevation: 0,
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    widget.message.isMe ? 'You' : widget.senderName,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  Text(
                    DateFormatter.messageDayHeader(widget.message.time),
                    style:
                        const TextStyle(fontSize: 12, color: Colors.white70),
                  ),
                ],
              ),
            )
          : null,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // The image, following the dismiss drag and shrinking slightly as it
          // is pulled away.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _chrome = !_chrome),
              onDoubleTapDown: (d) => _doubleTapDetails = d,
              onDoubleTap: _handleDoubleTap,
              // Drag-to-dismiss only when not zoomed; when zoomed the
              // InteractiveViewer owns panning.
              onVerticalDragUpdate: _zoomed ? null : _onDragUpdate,
              onVerticalDragEnd: _zoomed ? null : _onDragEnd,
              child: Transform.translate(
                offset: Offset(0, _dragDy),
                child: Transform.scale(
                  scale: (1 - (_dragDy.abs() / 1400)).clamp(0.85, 1.0),
                  child: Center(
                    child: Hero(
                      tag: 'photo_${widget.message.id}',
                      child: InteractiveViewer(
                        transformationController: _tc,
                        panEnabled: _zoomed,
                        minScale: 1,
                        maxScale: 4,
                        child: widget.message.imageUrl != null
                            ? ChatPhoto(
                                url: widget.message.imageUrl!,
                                fit: BoxFit.contain,
                                errorBuilder: (_) => _placeholder(colors),
                              )
                            : AspectRatio(
                                aspectRatio: 220 / 260,
                                child: _placeholder(colors)),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          // The transient like-heart pop.
          IgnorePointer(
            child: Center(
                child: FadeTransition(
              opacity: Tween<double>(begin: 1, end: 0).animate(CurvedAnimation(
                  parent: _burst, curve: const Interval(0.5, 1))),
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.6, end: 1.25).animate(
                    CurvedAnimation(parent: _burst, curve: Curves.elasticOut)),
                child: _burst.isAnimating
                    ? const Icon(Icons.favorite,
                        color: Color(0xFFFF3B5C), size: 120)
                    : const SizedBox.shrink(),
              ),
            )),
          ),
          // The bottom action bar — like + react — part of the chrome.
          if (_chrome && canReact)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: EdgeInsets.only(
                    top: 12,
                    bottom: 12 + MediaQuery.of(context).padding.bottom,
                    left: 24,
                    right: 24),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.55),
                      Colors.transparent,
                    ],
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _action(
                      icon: _liked ? Icons.favorite : Icons.favorite_border,
                      label: _liked ? 'Liked' : 'Like',
                      color: _liked ? const Color(0xFFFF3B5C) : Colors.white,
                      onTap: _toggleLike,
                    ),
                    const SizedBox(width: 40),
                    if (widget.onPickReaction != null)
                      _action(
                        icon: Icons.add_reaction_outlined,
                        label: 'React',
                        color: Colors.white,
                        onTap: widget.onPickReaction!,
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _action({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 26),
            const SizedBox(height: 2),
            Text(label,
                style: TextStyle(color: color, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
