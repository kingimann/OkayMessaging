import 'package:flutter/material.dart';
import 'package:random_avatar/random_avatar.dart';

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

  static Color parseHex(String raw, {int fallback = 0xFF9E9E9E}) {
    var hex = raw.replaceFirst('#', '');
    if (hex.length == 6) hex = 'FF$hex';
    return Color(int.tryParse(hex, radix: 16) ?? fallback);
  }

  Color get _color => parseHex(user.avatarColor);

  @override
  Widget build(BuildContext context) {
    final content = user.emoji.isNotEmpty
        ? Text(user.emoji, style: TextStyle(fontSize: radius * 0.9))
        : Text(
            user.initials,
            style: TextStyle(
              color: Colors.white,
              fontSize: radius * 0.7,
              fontWeight: FontWeight.w600,
            ),
          );
    // A second color turns the flat circle into a gradient — same size,
    // same content, so every screen that draws an avatar gets the look
    // without knowing it exists. The flat case stays a CircleAvatar.
    Widget core = user.avatarColor2.isEmpty
        ? CircleAvatar(radius: radius, backgroundColor: _color, child: content)
        : Container(
            width: radius * 2,
            height: radius * 2,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [_color, parseHex(user.avatarColor2)],
              ),
            ),
            child: content,
          );

    // A chosen illustrated avatar wins over colour/initials — a generated
    // Multiavatar character (offline, deterministic from the seed), clipped
    // to the same circle every avatar uses so it drops in everywhere.
    if (user.avatarSeed.isNotEmpty) {
      core = ClipOval(
        child: SizedBox(
          width: radius * 2,
          height: radius * 2,
          child: RandomAvatar(user.avatarSeed,
              height: radius * 2, width: radius * 2),
        ),
      );
    }

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
