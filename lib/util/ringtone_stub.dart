import 'package:flutter/services.dart';

/// Ring tones for native platforms. iOS answers on the okay/ringtone
/// channel with a real system chirp + ringer vibration; anywhere without
/// that channel (Android sideloads, tests) falls back to the platform's
/// generic alert sound, which is still better than the silence this used
/// to be.
const _channel = MethodChannel('okay/ringtone');

void ringBurst({required bool incoming}) {
  _channel.invokeMethod<void>('burst', incoming).catchError((_) {
    SystemSound.play(SystemSoundType.alert);
  });
}

void stopTone() {
  // Bursts are one-shot system sounds; nothing sustained to cut off.
}
