import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../relay/relay_service.dart';

/// The real audio/video media layer for calls, built on WebRTC.
///
/// The [CallService] state machine drives ringing / accept / hang-up and the
/// relay carries the signaling; this class owns the actual [RTCPeerConnection],
/// the microphone/camera streams and the video renderers. It is only active on
/// the web build (where the browser provides WebRTC); everywhere else — notably
/// unit tests on the Dart VM — every method is a safe no-op, so the tested
/// signaling logic is unaffected.
class CallMedia {
  CallMedia._();
  static final CallMedia instance = CallMedia._();

  RTCPeerConnection? _pc;
  MediaStream? _localStream;

  // Constructed lazily and only on web (in [_ensureRenderers]), so the Dart VM
  // used by tests never instantiates a platform video renderer.
  RTCVideoRenderer? localRenderer;
  RTCVideoRenderer? remoteRenderer;
  bool _renderersReady = false;

  /// Flips true once a remote track arrives, so the UI can show remote video.
  final ValueNotifier<bool> remoteReady = ValueNotifier<bool>(false);

  /// True while the local camera is capturing and enabled. Unlike the call's
  /// initial video flag, this tracks the LIVE state — a voice call where the
  /// user later turns the camera on flips this true, and the UI keys off it.
  final ValueNotifier<bool> localVideo = ValueNotifier<bool>(false);

  /// Live media connection state: 'new' | 'connecting' | 'connected' |
  /// 'disconnected' | 'failed' | 'closed'. The call UI reflects this so the
  /// user sees "Connecting…" / "Reconnecting…" rather than silence.
  final ValueNotifier<String> connectionState = ValueNotifier<String>('new');

  /// WebRTC media is available on every real platform flutter_webrtc supports
  /// (web + mobile/desktop). It is only inert on unsupported targets. All calls
  /// are additionally wrapped in try/catch, so the Dart VM used by unit tests
  /// (no platform plugin) is a harmless no-op.
  bool get isSupported {
    if (kIsWeb) return true;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
      case TargetPlatform.linux:
        return true;
      default:
        return false;
    }
  }

  // Optional TURN server (for calls behind strict/symmetric NATs) supplied at
  // build time: --dart-define=TURN_URL=... TURN_USERNAME=... TURN_CREDENTIAL=...
  static const String _turnUrl =
      String.fromEnvironment('TURN_URL', defaultValue: '');
  static const String _turnUser =
      String.fromEnvironment('TURN_USERNAME', defaultValue: '');
  static const String _turnCred =
      String.fromEnvironment('TURN_CREDENTIAL', defaultValue: '');

  // Public STUN servers cover most networks; TURN relays media when a direct
  // path can't be found — which on phones is COMMON, not rare: two devices on
  // cellular sit behind carrier-grade NAT, and STUN alone cannot connect
  // them. With no TURN at all those calls simply failed, and whether any
  // given call needed it depended on which networks the two phones happened
  // to be on that minute — "calls sometimes go through". When no private
  // TURN server is configured, Open Relay (Metered's free public TURN) is
  // the fallback: the relay only ever carries DTLS-SRTP ciphertext, so it
  // can route the call, not listen to it.
  static Map<String, dynamic> get _config => {
        'iceServers': [
          {'urls': 'stun:stun.l.google.com:19302'},
          {'urls': 'stun:stun1.l.google.com:19302'},
          if (_turnUrl.isNotEmpty)
            {
              'urls': _turnUrl,
              'username': _turnUser,
              'credential': _turnCred,
            }
          else ...[
            {
              'urls': 'turn:openrelay.metered.ca:80',
              'username': 'openrelayproject',
              'credential': 'openrelayproject',
            },
            {
              // 443 for networks that swallow everything else.
              'urls': 'turn:openrelay.metered.ca:443',
              'username': 'openrelayproject',
              'credential': 'openrelayproject',
            },
          ],
        ],
      };

  static String _mapState(RTCPeerConnectionState s) {
    switch (s) {
      case RTCPeerConnectionState.RTCPeerConnectionStateConnecting:
        return 'connecting';
      case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
        return 'connected';
      case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        return 'disconnected';
      case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        return 'failed';
      case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
        return 'closed';
      default:
        return 'new';
    }
  }

  Future<void> _ensureRenderers() async {
    if (_renderersReady) return;
    localRenderer = RTCVideoRenderer();
    remoteRenderer = RTCVideoRenderer();
    await localRenderer!.initialize();
    await remoteRenderer!.initialize();
    _renderersReady = true;
  }

  Future<void> _createPeer(String peerPhone, bool video) async {
    await _ensureRenderers();
    final pc = await createPeerConnection(_config);
    _pc = pc;
    // Echo cancellation + noise suppression + auto gain make voice calls
    // markedly cleaner than the bare defaults.
    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
      },
      'video': video ? {'facingMode': 'user'} : false,
    });
    localRenderer!.srcObject = _localStream;
    for (final track in _localStream!.getTracks()) {
      await pc.addTrack(track, _localStream!);
    }
    pc.onIceCandidate = (candidate) {
      if (candidate.candidate == null) return;
      RelayService.instance.sendIce(peerPhone, {
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };
    pc.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        remoteRenderer!.srcObject = event.streams.first;
        remoteReady.value = true;
      }
    };
    pc.onConnectionState = (state) {
      connectionState.value = _mapState(state);
    };
    connectionState.value = 'connecting';
    localVideo.value = video;
    _startStatsMonitor();
  }

  /// Caller side: opens the mic/camera and returns the SDP offer to signal.
  Future<String?> createOffer(String peerPhone, bool video) async {
    if (!isSupported) return null;
    try {
      await _createPeer(peerPhone, video);
      final offer = await _pc!.createOffer();
      await _pc!.setLocalDescription(offer);
      return offer.sdp;
    } catch (_) {
      return null;
    }
  }

  /// Callee side: answers a received [offerSdp], returning the SDP answer.
  Future<String?> createAnswer(
      String peerPhone, String offerSdp, bool video) async {
    if (!isSupported) return null;
    try {
      await _createPeer(peerPhone, video);
      await _pc!
          .setRemoteDescription(RTCSessionDescription(offerSdp, 'offer'));
      final answer = await _pc!.createAnswer();
      await _pc!.setLocalDescription(answer);
      await _flushPendingIce();
      return answer.sdp;
    } catch (_) {
      return null;
    }
  }

  /// Caller side: applies the callee's SDP answer.
  Future<void> setRemoteAnswer(String sdp) async {
    if (!isSupported || _pc == null) return;
    try {
      await _pc!.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
      await _flushPendingIce();
    } catch (_) {}
  }

  /// Remote candidates that arrived too early to apply. Both ends race:
  /// the caller's candidates land while the callee is still RINGING (no
  /// peer connection until they accept), and the callee's land at the
  /// caller before the answer is applied (no remote description yet).
  /// Candidates are signaled exactly once, so dropping an early one loses
  /// it for the whole call — which made connecting a coin flip decided by
  /// whose network gathered slowly enough.
  final List<Map<String, dynamic>> _pendingRemoteIce = [];
  bool _remoteDescriptionSet = false;

  Future<void> addIce(Map<String, dynamic> c) async {
    if (!isSupported) return;
    if (_pc == null || !_remoteDescriptionSet) {
      _pendingRemoteIce.add(Map<String, dynamic>.from(c));
      return;
    }
    try {
      await _pc!.addCandidate(RTCIceCandidate(
        c['candidate'] as String?,
        c['sdpMid'] as String?,
        (c['sdpMLineIndex'] as num?)?.toInt(),
      ));
    } catch (_) {}
  }

  /// Applies everything that arrived before the connection could take it.
  Future<void> _flushPendingIce() async {
    _remoteDescriptionSet = true;
    final queued = List<Map<String, dynamic>>.from(_pendingRemoteIce);
    _pendingRemoteIce.clear();
    for (final c in queued) {
      await addIce(c);
    }
  }

  // --- Mid-call renegotiation -------------------------------------------
  // Adding a brand-new track after the call is connected (camera on in a
  // voice call, or screen share when no video sender exists) does NOT reach
  // the peer until a fresh offer/answer round runs over the signaling relay.
  // Without this, "share screen" looked on but showed nothing remotely.

  /// Set when a new track was added and the connection must be re-offered.
  bool _renegotiateNeeded = false;

  /// Reads and clears the renegotiation flag (consumed by CallService).
  bool takeRenegotiateNeeded() {
    final v = _renegotiateNeeded;
    _renegotiateNeeded = false;
    return v;
  }

  /// Creates a fresh SDP offer on the LIVE connection (renegotiation).
  Future<String?> createRenegotiationOffer() async {
    if (!isSupported || _pc == null) return null;
    try {
      final offer = await _pc!.createOffer();
      await _pc!.setLocalDescription(offer);
      return offer.sdp;
    } catch (_) {
      return null;
    }
  }

  /// Answers a renegotiation offer received mid-call.
  Future<String?> answerRenegotiation(String offerSdp) async {
    if (!isSupported || _pc == null) return null;
    try {
      await _pc!
          .setRemoteDescription(RTCSessionDescription(offerSdp, 'offer'));
      final answer = await _pc!.createAnswer();
      await _pc!.setLocalDescription(answer);
      return answer.sdp;
    } catch (_) {
      return null;
    }
  }

  /// Turns the camera on/off, CAPTURING one on demand for calls that started
  /// voice-only (setVideoEnabled can only toggle tracks that already exist).
  /// Returns true when a new track was added — the caller must renegotiate.
  Future<bool> enableCamera(bool on) async {
    if (!isSupported) return false;
    try {
      final existing = _localStream?.getVideoTracks() ?? [];
      if (!on) {
        for (final t in existing) {
          t.enabled = false;
        }
        localVideo.value = false;
        return false;
      }
      if (existing.isNotEmpty) {
        for (final t in existing) {
          t.enabled = true;
        }
        if (!screenSharing.value && _localStream != null) {
          localRenderer?.srcObject = _localStream;
        }
        localVideo.value = true;
        return false;
      }
      // Voice call with no camera track yet: capture and add one.
      final cam = await navigator.mediaDevices.getUserMedia({
        'video': {'facingMode': 'user'},
      });
      final track = cam.getVideoTracks().first;
      if (_localStream != null) {
        await _localStream!.addTrack(track);
        if (_pc != null) {
          await _pc!.addTrack(track, _localStream!);
          _renegotiateNeeded = true;
        }
        if (!screenSharing.value) localRenderer?.srcObject = _localStream;
      }
      localVideo.value = true;
      return _renegotiateNeeded;
    } catch (_) {
      return false;
    }
  }

  MediaStream? _screenStream;

  /// True while this device is sharing its screen into the call.
  final ValueNotifier<bool> screenSharing = ValueNotifier<bool>(false);

  /// Starts/stops sharing this screen by swapping the outgoing video track.
  /// Returns null on success, or a human-readable reason it couldn't start
  /// (browsers gate this: desktop and Android Chrome allow it, iPhone
  /// Safari does not).
  Future<String?> toggleScreenShare() async {
    if (!isSupported || _pc == null) return 'No active call connection.';
    if (screenSharing.value) {
      await _stopScreenShare();
      return null;
    }
    try {
      final display = await navigator.mediaDevices
          .getDisplayMedia({'video': true, 'audio': false});
      final tracks = display.getVideoTracks();
      if (tracks.isEmpty) return 'Screen capture returned no video.';
      final track = tracks.first;
      final senders = await _pc!.getSenders();
      RTCRtpSender? videoSender;
      for (final s in senders) {
        if (s.track?.kind == 'video') {
          videoSender = s;
          break;
        }
      }
      if (videoSender != null) {
        await videoSender.replaceTrack(track);
      } else {
        // No video sender yet (the call started voice-only): adding the
        // track needs a renegotiation round before the peer can see it.
        await _pc!.addTrack(track, display);
        _renegotiateNeeded = true;
      }
      localRenderer?.srcObject = display;
      // The browser's own "Stop sharing" bar ends the track — follow it.
      track.onEnded = () => _stopScreenShare();
      _screenStream = display;
      screenSharing.value = true;
      return null;
    } catch (_) {
      return 'Screen sharing isn\'t available in this browser — iPhone '
          'Safari doesn\'t allow web screen capture; Android Chrome and '
          'desktop browsers do.';
    }
  }

  Future<void> _stopScreenShare() async {
    try {
      _screenStream?.getTracks().forEach((t) => t.stop());
      await _screenStream?.dispose();
    } catch (_) {}
    _screenStream = null;
    screenSharing.value = false;
    // Put the camera back on the wire and in the local preview.
    try {
      final cam = _localStream?.getVideoTracks() ?? [];
      final senders = await _pc?.getSenders() ?? <RTCRtpSender>[];
      for (final s in senders) {
        if (s.track?.kind == 'video' && cam.isNotEmpty) {
          await s.replaceTrack(cam.first);
        }
      }
      if (_localStream != null) localRenderer?.srcObject = _localStream;
    } catch (_) {}
  }

  /// True while the call is on hold (nothing sent, nothing played).
  final ValueNotifier<bool> onHold = ValueNotifier<bool>(false);

  /// Link quality from live WebRTC stats: 3 = good, 2 = fair, 1 = poor,
  /// 0 = unknown/no data yet. Drives the signal bars on the call screen.
  final ValueNotifier<int> quality = ValueNotifier<int>(0);

  Timer? _statsTimer;
  int _lastLost = 0;
  int _lastReceived = 0;

  /// Maps a packet-loss ratio to quality bars. Pure, so it's easy to test.
  static int qualityForLoss(double lossRatio) {
    if (lossRatio >= 0.08) return 1; // audible dropouts
    if (lossRatio >= 0.02) return 2; // noticeable but usable
    return 3;
  }

  /// Polls the peer connection for inbound packet loss while a call runs.
  void _startStatsMonitor() {
    _statsTimer?.cancel();
    _lastLost = 0;
    _lastReceived = 0;
    _statsTimer =
        Timer.periodic(const Duration(seconds: 3), (_) => _sampleStats());
  }

  Future<void> _sampleStats() async {
    final pc = _pc;
    if (pc == null) return;
    try {
      final reports = await pc.getStats();
      var lost = 0;
      var received = 0;
      for (final r in reports) {
        if (r.type != 'inbound-rtp') continue;
        lost += (r.values['packetsLost'] as num?)?.toInt() ?? 0;
        received += (r.values['packetsReceived'] as num?)?.toInt() ?? 0;
      }
      // Compare against the previous sample so quality reflects *now*,
      // not the whole call's history.
      final dLost = (lost - _lastLost).clamp(0, 1 << 30);
      final dReceived = (received - _lastReceived).clamp(0, 1 << 30);
      _lastLost = lost;
      _lastReceived = received;
      final total = dLost + dReceived;
      if (total <= 0) return; // no traffic in this window — keep last reading
      quality.value = qualityForLoss(dLost / total);
    } catch (_) {
      // Stats are unavailable on some platforms; leave the last reading.
    }
  }

  /// Holds/resumes the call: stops sending audio and video, and silences
  /// the incoming stream, without tearing the connection down.
  void setHold(bool held) {
    onHold.value = held;
    _localStream?.getTracks().forEach((t) => t.enabled = !held);
    try {
      remoteRenderer?.muted = held;
    } catch (_) {}
  }

  void setMuted(bool muted) {
    _localStream?.getAudioTracks().forEach((t) => t.enabled = !muted);
  }

  void setVideoEnabled(bool enabled) {
    _localStream?.getVideoTracks().forEach((t) => t.enabled = enabled);
  }

  /// Routes call audio to the loudspeaker (on) or the earpiece (off).
  Future<void> setSpeaker(bool on) async {
    if (!isSupported) return;
    try {
      await Helper.setSpeakerphoneOn(on);
    } catch (_) {}
  }

  /// Flips between the front and back camera during a video call.
  Future<void> switchCamera() async {
    if (!isSupported || _localStream == null) return;
    try {
      final tracks = _localStream!.getVideoTracks();
      if (tracks.isNotEmpty) await Helper.switchCamera(tracks.first);
    } catch (_) {}
  }

  /// Whether a local video track exists (a video call with the camera on).
  bool get hasLocalVideo =>
      (_localStream?.getVideoTracks().isNotEmpty ?? false);

  Future<void> hangUp() async {
    remoteReady.value = false;
    connectionState.value = 'closed';
    screenSharing.value = false;
    localVideo.value = false;
    _renegotiateNeeded = false;
    _pendingRemoteIce.clear();
    _remoteDescriptionSet = false;
    onHold.value = false;
    _statsTimer?.cancel();
    _statsTimer = null;
    quality.value = 0;
    try {
      _screenStream?.getTracks().forEach((t) => t.stop());
      await _screenStream?.dispose();
    } catch (_) {}
    _screenStream = null;
    try {
      _localStream?.getTracks().forEach((t) => t.stop());
      await _localStream?.dispose();
      await _pc?.close();
    } catch (_) {}
    _localStream = null;
    _pc = null;
    if (_renderersReady) {
      localRenderer?.srcObject = null;
      remoteRenderer?.srcObject = null;
    }
  }
}
