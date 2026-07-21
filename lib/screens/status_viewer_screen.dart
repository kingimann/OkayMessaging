import 'package:flutter/material.dart';

import '../models/status.dart';
import '../utils/date_formatter.dart';
import '../widgets/user_avatar.dart';

/// Full-screen story viewer with segmented progress bars and auto-advance,
/// modeled on WhatsApp's Status viewer.
class StatusViewerScreen extends StatefulWidget {
  final StatusUpdate status;

  const StatusViewerScreen({super.key, required this.status});

  @override
  State<StatusViewerScreen> createState() => _StatusViewerScreenState();
}

class _StatusViewerScreenState extends State<StatusViewerScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  int _index = 0;

  static const _captions = [
    'Beautiful day out here ☀️',
    'Coffee time ☕',
    'Working on something new 🚀',
    'Throwback to last weekend 🌊',
    'Guess where I am 👀',
  ];

  static const _bgColors = [
    Color(0xFF1F3A5F),
    Color(0xFF4A2E5F),
    Color(0xFF0B4F4A),
    Color(0xFF5F3A1F),
    Color(0xFF3A1F5F),
  ];

  int get _frameCount => widget.status.frameCount;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..addStatusListener((s) {
        if (s == AnimationStatus.completed) _next();
      });
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _next() {
    if (_index < _frameCount - 1) {
      setState(() => _index++);
      _controller
        ..reset()
        ..forward();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  void _prev() {
    if (_index > 0) {
      setState(() => _index--);
      _controller
        ..reset()
        ..forward();
    } else {
      _controller
        ..reset()
        ..forward();
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = widget.status.user;
    final bg = _bgColors[_index % _bgColors.length];

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            // Tappable navigation zones.
            Positioned.fill(
              child: Row(
                children: [
                  Expanded(
                    flex: 1,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _prev,
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _next,
                    ),
                  ),
                ],
              ),
            ),
            IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [bg, bg.withValues(alpha: 0.7)],
                  ),
                ),
                alignment: Alignment.center,
                margin: const EdgeInsets.only(top: 70, bottom: 80),
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    _captions[_index % _captions.length],
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                    ),
                  ),
                ),
              ),
            ),
            // Progress bars.
            Positioned(
              top: 8,
              left: 8,
              right: 8,
              child: Row(
                children: [
                  for (var i = 0; i < _frameCount; i++)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: _SegmentBar(
                          controller: _controller,
                          filled: i < _index,
                          active: i == _index,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            // Header.
            Positioned(
              top: 20,
              left: 8,
              right: 8,
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  UserAvatar(user: user, radius: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(user.name,
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600)),
                        Text(
                          DateFormatter.statusLabel(widget.status.time),
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // Reply bar (visual only).
            Positioned(
              bottom: 12,
              left: 16,
              right: 16,
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.white54),
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: const Text('Reply to status',
                          style: TextStyle(color: Colors.white70)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Icon(Icons.send, color: Colors.white),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SegmentBar extends StatelessWidget {
  final AnimationController controller;
  final bool filled;
  final bool active;

  const _SegmentBar({
    required this.controller,
    required this.filled,
    required this.active,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: SizedBox(
        height: 3,
        child: filled
            ? Container(color: Colors.white)
            : active
                ? AnimatedBuilder(
                    animation: controller,
                    builder: (context, _) => LinearProgressIndicator(
                      value: controller.value,
                      backgroundColor: Colors.white30,
                      valueColor: const AlwaysStoppedAnimation(Colors.white),
                    ),
                  )
                : Container(color: Colors.white30),
      ),
    );
  }
}
