import 'package:web/web.dart' as web;

/// Synthesised ring tones via the Web Audio API — no audio assets to ship
/// and nothing to fetch over the network (which the tile CDNs taught us to
/// avoid depending on).
web.AudioContext? _ctx;

web.AudioContext? _context() {
  try {
    return _ctx ??= web.AudioContext();
  } catch (_) {
    return null;
  }
}

/// Plays one ring "burst": the classic double beep for an incoming call, a
/// single softer tone for the outgoing ring-back.
void ringBurst({required bool incoming}) {
  final ctx = _context();
  if (ctx == null) return;
  try {
    final now = ctx.currentTime.toDouble();
    // An incoming ring is two chirps; ring-back is one longer, quieter tone.
    if (incoming) {
      _tone(ctx, start: now, duration: 0.35, freq: 660, volume: 0.16);
      _tone(ctx, start: now + 0.45, duration: 0.35, freq: 660, volume: 0.16);
    } else {
      _tone(ctx, start: now, duration: 0.9, freq: 420, volume: 0.06);
    }
  } catch (_) {
    // A blocked or unavailable audio context just means a silent ring.
  }
}

/// One enveloped sine tone, so it fades in and out instead of clicking.
void _tone(
  web.AudioContext ctx, {
  required double start,
  required double duration,
  required double freq,
  required double volume,
}) {
  final osc = ctx.createOscillator();
  final gain = ctx.createGain();
  osc.type = 'sine';
  osc.frequency.value = freq;
  gain.gain.setValueAtTime(0, start);
  gain.gain.linearRampToValueAtTime(volume, start + 0.04);
  gain.gain.linearRampToValueAtTime(0, start + duration);
  osc.connect(gain);
  gain.connect(ctx.destination);
  osc.start(start);
  osc.stop(start + duration + 0.02);
}

void stopTone() {
  try {
    _ctx?.close();
  } catch (_) {}
  _ctx = null;
}
