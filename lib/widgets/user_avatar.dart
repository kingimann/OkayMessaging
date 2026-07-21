import 'package:flutter/material.dart';

import '../models/user.dart';

/// A circular placeholder avatar showing the user's initials on a colored
/// background (no network images are used in this UI-only clone).
class UserAvatar extends StatelessWidget {
  final AppUser user;
  final double radius;

  const UserAvatar({super.key, required this.user, this.radius = 26});

  Color get _color {
    var hex = user.avatarColor.replaceFirst('#', '');
    if (hex.length == 6) hex = 'FF$hex';
    final value = int.tryParse(hex, radix: 16) ?? 0xFF9E9E9E;
    return Color(value);
  }

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
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
  }
}
