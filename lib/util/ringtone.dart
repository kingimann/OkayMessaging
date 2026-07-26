import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'ringtone_stub.dart' if (dart.library.js_interop) 'ringtone_web.dart'
    as impl;

/// Test hook: records ring bursts instead of making noise.
@visibleForTesting
void Function({required bool incoming})? debugRingOverride;

Timer? _loop;

/// True while a ring pattern is playing.
bool get isRinging => _loop != null;

/// Starts ringing until [stopRinging]: a repeating double-chirp for an
/// incoming call (with vibration), or a quieter ring-back while an outgoing
/// call waits to be answered.
void startRinging({required bool incoming}) {
  stopRinging();
  _burst(incoming: incoming);
  _loop = Timer.periodic(
    Duration(milliseconds: incoming ? 2600 : 4000),
    (_) => _burst(incoming: incoming),
  );
}

void _burst({required bool incoming}) {
  final debug = debugRingOverride;
  if (debug != null) {
    debug(incoming: incoming);
    return;
  }
  impl.ringBurst(incoming: incoming);
  // A ringing phone should be felt as well as heard.
  if (incoming) {
    try {
      HapticFeedback.mediumImpact();
    } catch (_) {}
  }
}

void stopRinging() {
  _loop?.cancel();
  _loop = null;
  if (debugRingOverride != null) return;
  impl.stopTone();
}
