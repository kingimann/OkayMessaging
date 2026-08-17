import 'package:flutter/animation.dart';

/// One motion scale, for the same reason there is one radius scale.
///
/// The app had **twelve** distinct animation durations in use (150, 200, 220,
/// 250, 300, 400, 420, 500, 650, 700, 900, 1200) — each defensible alone, and
/// the set of them the reason motion reads as assembled rather than designed:
/// two things that should feel like the same gesture take different lengths
/// of time, and nothing tells you which one a new animation should match.
///
/// Pick by what the motion IS, not by how big the thing moving is:
///
///  * [fast] — a control answering a touch. A pill selecting, a chip filling,
///    a row highlighting. Short enough that it reads as response, not travel.
///  * [base] — one piece of content replacing another. A tab cross-fading, a
///    panel opening, a message arriving, an error appearing.
///  * [slow] — something crossing a distance, or asking to be noticed: a
///    sheet, a first-run reveal.
///
/// Anything longer than [slow] is not on this scale on purpose. A ringtone
/// pulse, a typing indicator, a shimmer — those are loops rather than
/// transitions, they are timed by what they represent, and forcing them onto
/// a scale built for transitions would make both worse.
class AppMotion {
  AppMotion._();

  static const Duration fast = Duration(milliseconds: 150);
  static const Duration base = Duration(milliseconds: 240);
  static const Duration slow = Duration(milliseconds: 380);

  /// The default for anything entering or settling. Decelerating motion reads
  /// as a thing arriving and coming to rest; linear reads as a thing being
  /// dragged by a machine.
  static const Curve enter = Curves.easeOutCubic;

  /// For something leaving. Accelerating out is quicker to the eye than it is
  /// on the clock, which is what keeps a dismissal from feeling slow.
  static const Curve exit = Curves.easeInCubic;

  /// Both ends of a move that starts and finishes on screen.
  static const Curve move = Curves.easeInOutCubic;

  /// A little overshoot, for something that should feel physical — a bubble
  /// landing, a badge popping. Used sparingly: on a list of many, overshoot
  /// stops being delight and becomes noise.
  static const Curve pop = Curves.easeOutBack;
}
