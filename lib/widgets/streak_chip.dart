import 'package:flutter/material.dart';

/// A compact flame + day-count chip for a conversation streak (à la Snapchat).
/// Uses a Material fire icon rather than an emoji so it renders everywhere.
/// When [expiring], an amber hourglass warns the streak needs a message today.
class StreakChip extends StatelessWidget {
  final int count;
  final double size;
  final bool expiring;

  const StreakChip({
    super.key,
    required this.count,
    this.size = 15,
    this.expiring = false,
  });

  @override
  Widget build(BuildContext context) {
    final color =
        expiring ? const Color(0xFFF9A825) : const Color(0xFFFF7043);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (expiring) ...[
          Icon(Icons.hourglass_bottom,
              size: size, color: const Color(0xFFF9A825)),
          const SizedBox(width: 1),
        ],
        Icon(Icons.local_fire_department, size: size, color: color),
        const SizedBox(width: 1),
        Text(
          '$count',
          style: TextStyle(
            fontSize: size * 0.82,
            fontWeight: FontWeight.w700,
            color: color,
          ),
        ),
      ],
    );
  }
}
