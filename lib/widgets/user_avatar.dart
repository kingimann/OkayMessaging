import 'package:flutter/material.dart';
import 'package:random_avatar/random_avatar.dart';

import '../models/user.dart';
import '../util/avatar_face.dart';
import '../util/avatar_gif.dart';
import 'chat_photo.dart';

/// The one avatar in the app: a colour and initials, an emoji, a generated
/// character, a built face, or a GIF — whichever the person actually chose,
/// most deliberate first.
///
/// Four of the five draw with no network at all. The fifth, a GIF, is fetched
/// from whoever serves it; [AvatarGif] states what that costs and what bounds
/// it.
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

    // A face somebody BUILT wins over everything, because it is the most
    // deliberate of the three: a colour is assigned, a generated character is
    // picked off a grid, this one was assembled feature by feature. Its
    // fallback is whatever the colour/initials branch above just built, so a
    // selection this build cannot draw is a normal avatar rather than a hole.
    //
    // Assigned to [core] rather than returned, or the presence dot and the
    // hero below would be skipped for exactly the people who bothered to
    // make a face.
    if (user.avatarFace.isNotEmpty) {
      core = AvatarFaceView(
          selection: user.avatarFace, size: radius * 2, fallback: core);
    } else if (user.avatarSeed.isNotEmpty) {
      core = ClipOval(
        child: SizedBox(
          width: radius * 2,
          height: radius * 2,
          child: RandomAvatar(user.avatarSeed,
              height: radius * 2, width: radius * 2),
        ),
      );
    }

    // A GIF wins over all of it — the only one of the four that is a real
    // picture rather than something the app drew, and what people mean by a
    // profile picture. Layered ON TOP rather than instead of, so whatever was
    // underneath is what shows while the fetch is in flight, if it fails, and
    // the moment the GIF is taken off again.
    if (AvatarGif.looksValid(user.avatarGif)) {
      // Captured, not read from [core] inside the builder: a closure captures
      // the VARIABLE, so `errorBuilder: (_) => core` would hand back the GIF
      // that just failed and draw it again, forever.
      final under = core;
      core = ClipOval(
        child: SizedBox(
          width: radius * 2,
          height: radius * 2,
          child: ChatPhoto(
            url: user.avatarGif,
            errorBuilder: (_) => under,
          ),
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
