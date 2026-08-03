import 'package:flutter_webrtc/flutter_webrtc.dart';

/// The clarity knobs Discord turns and stock WebRTC leaves alone, in one
/// place so the 1:1 call and the voice-channel mesh cannot drift apart.
///
/// Three layers, all standard WebRTC — no extra server, nothing proprietary:
///
///  1. **The processed mic.** Echo cancellation, noise suppression and auto
///     gain, asked for explicitly (defaults vary per platform), at Opus's
///     native 48 kHz.
///  2. **Opus, run the way voice apps run it.** The SDP an offer/answer
///     carries decides how the FAR side encodes toward us: in-band FEC (a
///     lost packet is reconstructed instead of heard as a dropout), DTX
///     (silence costs ~nothing, leaving bandwidth for speech), and a 64 kbps
///     ceiling instead of the ~32 kbps default — Discord's own default rate.
///  3. **Content-aware video.** A screen share is DETAIL: hold resolution,
///     let the frame rate fall (crisp text at 5 fps beats soup at 30). A
///     camera is MOTION: hold the frame rate, let resolution fall.
class CallQuality {
  CallQuality._();

  /// Opus ceiling for voice. 64 kbps is transparent for speech and is what
  /// Discord ships as its default quality.
  static const int voiceBitrate = 64000;

  /// getUserMedia audio constraints — the full processed chain, requested
  /// explicitly. The goog* duplicates reach Chrome's stronger pipeline where
  /// it exists; unknown keys are ignored everywhere else.
  static Map<String, dynamic> micConstraints() => {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
        'sampleRate': 48000,
        'channelCount': 1,
        'googEchoCancellation': true,
        'googNoiseSuppression': true,
        'googAutoGainControl': true,
        'googHighpassFilter': true,
      };

  /// getUserMedia camera constraints: 720p30 as the ceiling, not a demand —
  /// `ideal` lets a weak device or link deliver less instead of failing.
  static Map<String, dynamic> cameraConstraints() => {
        'facingMode': 'user',
        'width': {'ideal': 1280},
        'height': {'ideal': 720},
        'frameRate': {'ideal': 30},
      };

  /// Rewrites the Opus `fmtp` line of an outgoing SDP. The fmtp in an offer
  /// or answer describes what the SENDER OF THE SDP wants to receive, so
  /// tuning the string we hand to signaling — never the local description —
  /// is both correct and safe: it configures the far side's encoder toward
  /// us and touches nothing locally.
  ///
  /// Pure string-in string-out, so a test can pin exactly what it does.
  static String tuneOpus(String sdp, {int bitrate = voiceBitrate}) {
    // The WHOLE rtpmap line — a prefix match would split "opus/48000/2"
    // when inserting after it.
    final rtpmap = RegExp(r'a=rtpmap:(\d+) opus/48000[^\r\n]*');
    final match = rtpmap.firstMatch(sdp);
    if (match == null) return sdp; // no Opus — nothing to tune
    final pt = match.group(1)!;
    final adds = <String, String>{
      'useinbandfec': '1',
      'usedtx': '1',
      'maxaveragebitrate': '$bitrate',
      'maxplaybackrate': '48000',
    };
    final tuned =
        adds.entries.map((e) => '${e.key}=${e.value}').join(';');
    final existing = RegExp('a=fmtp:$pt ([^\r\n]+)').firstMatch(sdp);
    if (existing != null) {
      // Keep whatever else the platform negotiated (minptime, etc.);
      // replace stale values for our keys rather than stacking duplicates.
      final kept = existing
          .group(1)!
          .split(';')
          .where((kv) =>
              kv.trim().isNotEmpty &&
              !adds.containsKey(kv.split('=').first.trim()))
          .toList();
      final params = [...kept, tuned].join(';');
      return sdp.replaceFirst(existing.group(0)!, 'a=fmtp:$pt $params');
    }
    // No fmtp line for Opus at all: add one right after its rtpmap line.
    return sdp.replaceFirst(
        match.group(0)!, '${match.group(0)!}\r\na=fmtp:$pt $tuned');
  }

  /// Tunes every VIDEO sender on [pc] for what it is carrying right now.
  /// Best-effort on purpose: parameters vary by platform, and a call that
  /// connects untuned beats one that crashed tuning itself.
  /// [bitrateOverride] is the adaptive controller's current rate — when set
  /// it replaces the static ceiling, so a struggling link is actually
  /// listened to.
  static Future<void> tuneVideoSenders(RTCPeerConnection pc,
      {required bool screen, int? bitrateOverride}) async {
    try {
      for (final sender in await pc.getSenders()) {
        if (sender.track?.kind != 'video') continue;
        final params = sender.parameters;
        final encodings = params.encodings;
        if (encodings == null || encodings.isEmpty) continue;
        for (final e in encodings) {
          // Screen: room for crisp text. Camera: enough for smooth 720p.
          e.maxBitrate = bitrateOverride ?? (screen ? 2500000 : 1200000);
          e.maxFramerate = screen ? 15 : 30;
        }
        params.degradationPreference = screen
            ? RTCDegradationPreference.MAINTAIN_RESOLUTION
            : RTCDegradationPreference.MAINTAIN_FRAMERATE;
        await sender.setParameters(params);
      }
    } catch (_) {}
  }

  /// Whether a stats audio level means somebody is talking. 0.02 is well
  /// above processed-mic noise floors and well below any actual speech.
  static bool audible(double? level) => (level ?? 0) > 0.02;
}

/// Video bitrate that follows the link — AIMD, the shape TCP and every
/// congestion controller since have used: back off hard when the link
/// drops packets, creep back up when it stays clean. WebRTC's own bandwidth
/// estimation adapts *below* the cap; this moves the cap itself, so a link
/// that fell over at 2.5 Mbps isn't asked for 2.5 Mbps again two seconds
/// after recovering.
class AdaptiveBitrate {
  AdaptiveBitrate({
    required this.floor,
    required this.ceiling,
    int? start,
  }) : rate = start ?? ceiling;

  final int floor;
  final int ceiling;
  int rate;

  /// Feeds one loss sample. Returns true when the rate changed and the
  /// caller should re-apply it to the senders.
  bool sample(double lossRatio) {
    final before = rate;
    if (lossRatio >= 0.05) {
      // Multiplicative decrease: real loss means the link is over-asked.
      rate = (rate * 0.7).round().clamp(floor, ceiling);
    } else if (lossRatio <= 0.01) {
      // Additive increase: a clean window earns a small raise.
      rate = (rate + 100000).clamp(floor, ceiling);
    }
    return rate != before;
  }
}
