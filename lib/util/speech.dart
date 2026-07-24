import 'package:flutter/foundation.dart';

import 'speech_stub.dart' if (dart.library.js_interop) 'speech_web.dart'
    as impl;

/// Test hook: captures spoken prompts instead of using the platform engine.
@visibleForTesting
void Function(String text)? debugSpeakOverride;

/// Speaks [text] aloud (browser SpeechSynthesis on the web; silent no-op
/// where no engine exists).
void speak(String text) {
  final debug = debugSpeakOverride;
  if (debug != null) {
    debug(text);
    return;
  }
  impl.speak(text);
}

/// Stops any in-progress speech.
void stopSpeaking() {
  if (debugSpeakOverride != null) return;
  impl.stop();
}
