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

  /// WebRTC media is only wired up on the web build.
  bool get isSupported => kIsWeb;

  // Public STUN servers handle NAT traversal for most networks. Calls behind
  // strict/symmetric NATs would additionally need a TURN server (see docs).
  static const Map<String, dynamic> _config = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
    ],
  };

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
    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
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
    } catch (_) {}
  }

  Future<void> addIce(Map<String, dynamic> c) async {
    if (!isSupported || _pc == null) return;
    try {
      await _pc!.addCandidate(RTCIceCandidate(
        c['candidate'] as String?,
        c['sdpMid'] as String?,
        (c['sdpMLineIndex'] as num?)?.toInt(),
      ));
    } catch (_) {}
  }

  void setMuted(bool muted) {
    _localStream?.getAudioTracks().forEach((t) => t.enabled = !muted);
  }

  void setVideoEnabled(bool enabled) {
    _localStream?.getVideoTracks().forEach((t) => t.enabled = enabled);
  }

  Future<void> hangUp() async {
    remoteReady.value = false;
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
