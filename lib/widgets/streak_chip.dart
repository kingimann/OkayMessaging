import 'package:flutter/material.dart';

/// A compact flame + day-count chip for a conversation streak (à la Snapchat).
/// Uses a Material fire icon rather than an emoji so it renders everywhere.
class StreakChip extends StatelessWidget {
  final int count;
  final double size;

  const StreakChip({super.key, required this.count, this.size = 15});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.local_fire_department,
            size: size, color: const Color(0xFFFF7043)),
        const SizedBox(width: 1),
        Text(
          '$count',
          style: TextStyle(
            fontSize: size * 0.82,
            fontWeight: FontWeight.w700,
            color: const Color(0xFFFF7043),
          ),
        ),
      ],
    );
  }
}
