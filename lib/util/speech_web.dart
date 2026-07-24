import 'package:web/web.dart' as web;

/// Speaks [text] via the browser's built-in speech synthesis. A new prompt
/// interrupts the previous one — stale directions are worse than silence.
void speak(String text) {
  try {
    final utterance = web.SpeechSynthesisUtterance(text)..rate = 1.0;
    web.window.speechSynthesis.cancel();
    web.window.speechSynthesis.speak(utterance);
  } catch (_) {
    // No speech engine — navigation continues silently.
  }
}

void stop() {
  try {
    web.window.speechSynthesis.cancel();
  } catch (_) {}
}
