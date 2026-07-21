import 'package:flutter/material.dart';

import '../models/user.dart';

/// A circular placeholder avatar showing the user's initials on a colored
/// background (no network images are used in this UI-only clone).
class UserAvatar extends StatelessWidget {
  final AppUser user;
  final double radius;

  /// When set, the avatar animates between screens as a shared element.
  final String? heroTag;

  /// When true, shows a small green presence dot for online users.
  final bool showPresence;

  const UserAvatar({
    super.key,
    required this.user,
    this.radius = 26,
    this.heroTag,
    this.showPresence = false,
  });

  Color get _color {
    var hex = user.avatarColor.replaceFirst('#', '');
    if (hex.length == 6) hex = 'FF$hex';
    final value = int.tryParse(hex, radix: 16) ?? 0xFF9E9E9E;
    return Color(value);
  }

  @override
  Widget build(BuildContext context) {
    Widget core = CircleAvatar(
      radius: radius,
      backgroundColor: _color,
      child: Text(
        user.initials,
        style: TextStyle(
          color: Colors.white,
          fontSize: radius * 0.7,
          fontWeight: FontWeight.w600,
        ),
      ),
    );

    if (showPresence && user.isOnline) {
      final dot = radius * 0.42;
      core = Stack(
        clipBehavior: Clip.none,
        children: [
          core,
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: dot,
              height: dot,
              decoration: BoxDecoration(
                color: const Color(0xFF25D366),
                shape: BoxShape.circle,
                border: Border.all(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  width: 2,
                ),
              ),
            ),
          ),
        ],
      );
    }

    if (heroTag == null) return core;
    return Hero(
      tag: heroTag!,
      child: Material(type: MaterialType.transparency, child: core),
    );
  }
}
