import 'package:flutter/services.dart';

/// The app's one place for touch feedback, so every surface taps with the
/// same weight instead of each screen picking its own — or, as it was,
/// nothing anywhere. Three weights, chosen by what the moment means rather
/// than by which widget fired it:
///
/// - [tap] for something that happened: a message left, a reaction stuck.
/// - [press] for something that opened under a held finger: a message's
///   action sheet, a recording starting.
/// - [select] for moving between states: a tab switch, a picker step.
///
/// Everything funnels through [_fire] so tests can count what fired
/// ([debugCount]) — the real channel is a platform call that a test can
/// neither feel nor observe.
class Haptics {
  Haptics._();

  /// How many haptics have fired, visible to tests.
  static int debugCount = 0;

  static void _fire(Future<void> Function() kind) {
    debugCount++;
    // The platform call can only fail where there is no platform (tests,
    // web); silence is the correct behaviour there, not an error.
    try {
      kind();
    } catch (_) {}
  }

  /// A light tick — an action completed (send, react, refresh).
  static void tap() => _fire(HapticFeedback.lightImpact);

  /// A firmer knock — a long-press surface opening, a recording starting.
  static void press() => _fire(HapticFeedback.mediumImpact);

  /// The selection click — switching tabs, stepping a picker.
  static void select() => _fire(HapticFeedback.selectionClick);
}
