/// The shape every self-test in the app reports in: a list of things that were
/// checked, and one sentence about what to do.
///
/// Extracted from the payments self-test when push needed the same thing. Both
/// answer a question a dashboard cannot: whether a set of secrets somebody
/// pasted into a server is the set the app actually needs. The screen that
/// renders this is shared too — see SelfTestScreen.
library;

/// One line of a self-test. Named CheckState rather than StepState because
/// Material already has a StepState and the clash is silent until it is not.
enum CheckState { pass, fail, unknown }

class DiagnosticStep {
  final String title;

  /// What was found. Shown verbatim, so it must never contain a secret.
  final String detail;
  final CheckState state;

  const DiagnosticStep(this.title, this.detail, this.state);
}

/// What a self-test found, and the one sentence worth acting on.
class SelfTestReport {
  /// Names which self-test this is, so a pasted report says what it is about.
  final String title;

  final List<DiagnosticStep> steps;

  /// The fix, or a statement that nothing looks wrong from here.
  final String verdict;

  /// Whether [verdict] names a fault rather than a clean result.
  final bool faulty;

  const SelfTestReport(
      {this.title = 'Self-test',
      required this.steps,
      required this.verdict,
      required this.faulty});

  /// A block of text somebody can paste into a message. Every step is written
  /// to be readable on its own, and no step carries a secret — so this is safe
  /// to send, but it is written to be read rather than parsed.
  String get report => [
        title,
        for (final s in steps)
          '${switch (s.state) {
            CheckState.pass => '[ok]  ',
            CheckState.fail => '[FAIL]',
            CheckState.unknown => '[ ? ] ',
          }} ${s.title}: ${s.detail}',
        '',
        verdict,
      ].join('\n');
}
