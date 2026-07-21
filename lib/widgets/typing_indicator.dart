import 'package:flutter/material.dart';

/// A compact animated "typing" indicator: three dots that pulse in sequence.
class TypingIndicator extends StatefulWidget {
  final Color color;

  const TypingIndicator({super.key, required this.color});

  @override
  State<TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<TypingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text('typing', style: TextStyle(fontSize: 12.5, color: widget.color)),
        const SizedBox(width: 3),
        for (var i = 0; i < 3; i++)
          Padding(
            padding: const EdgeInsets.only(right: 2, bottom: 2),
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, _) {
                // Stagger each dot's pulse across the cycle.
                final t = (_controller.value - i * 0.2) % 1.0;
                final scale = 0.5 + 0.5 * (t < 0.5 ? t * 2 : (1 - t) * 2);
                return Container(
                  width: 4,
                  height: 4,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.color.withValues(alpha: 0.4 + 0.6 * scale),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}
