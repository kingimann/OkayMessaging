import 'package:flutter/material.dart';

/// A name-only placeholder avatar: initials on a color derived deterministically
/// from the name.
///
/// [UserAvatar] needs a full [AppUser] (avatar color, emoji, illustrated seed),
/// which a server channel's roster entry ([Member]) does not carry — a
/// [Message] in a channel has nothing but the sender's plain [senderName].
/// This is the lighter-weight fallback for exactly that case, and it is also
/// the one place the name→color mapping lives, so a name always gets the
/// SAME color wherever it is shown — the sender label above a group chat
/// bubble ([_SenderLabel] in message_bubble.dart, which delegates to
/// [colorFor] rather than keeping its own copy) and a channel message's name
/// label and avatar both read off this one palette.
class InitialsAvatar extends StatelessWidget {
  final String name;
  final double radius;

  const InitialsAvatar({super.key, required this.name, this.radius = 13});

  static const _palette = [
    Color(0xFF1F8AC0),
    Color(0xFFC0392B),
    Color(0xFF7D3C98),
    Color(0xFF117864),
    Color(0xFFB9770E),
    Color(0xFF2E4053),
  ];

  static Color colorFor(String name) =>
      _palette[name.hashCode.abs() % _palette.length];

  static String initialsFor(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '?';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: radius,
      backgroundColor: colorFor(name),
      child: Text(
        initialsFor(name),
        style: TextStyle(
          color: Colors.white,
          fontSize: radius * 0.75,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
