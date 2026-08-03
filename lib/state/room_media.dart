import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'call_media.dart';
import 'call_quality.dart';
import 'session.dart';
import 'voice_presence_store.dart';

/// Real media for voice channels: a WebRTC MESH, one peer connection per
/// occupant, discovered from the presence store this app already runs.
///
/// Discord does this with an SFU — a media server every member sends one
/// stream to. This app has no media server on principle (nothing readable
/// ever sits on one), so the mesh is the honest architecture: every pair of
/// members connects directly, media stays DTLS-SRTP end-to-end, and the
/// signaling rides the same sealed pairwise relay path calls use. The cost
/// is bandwidth that grows with the room — a mesh is comfortable to roughly
/// eight people, which is a voice channel, not a conference hall.
///
/// Roles are fixed the way the ratchet fixed them: for any pair, the SMALLER
/// digit-string makes the offer and the other answers, so two devices
/// discovering each other at the same instant cannot collide head-on.
class RoomMedia extends ChangeNotifier {
  RoomMedia._();
  static final RoomMedia instance = RoomMedia._();

  /// Sends one signaling event — wired to [RelayService.sendRoomSignal] at
  /// startup; left null in tests so nothing touches the network.
  void Function(String toDigits,
      {required String roomId,
      required String kind,
      String? sdp,
      Map<String, dynamic>? ice})? send;

  String? _roomId;
  String? _channelId;
  MediaStream? _localStream;
  MediaStream? _screenStream;
  final Map<String, RTCPeerConnection> _peers = {};
  final Map<String, RTCVideoRenderer> _remoteRenderers = {};
  final Map<String, List<Map<String, dynamic>>> _pendingIce = {};
  final Set<String> _remoteDescribed = {};
  RTCVideoRenderer? localRenderer;

  /// Whether this device is in a room with live media.
  bool get active => _roomId != null;

  /// True while the local camera / screen is being sent into the room.
  final ValueNotifier<bool> cameraOn = ValueNotifier<bool>(false);
  final ValueNotifier<bool> screenSharing = ValueNotifier<bool>(false);

  bool get isSupported => CallMedia.instance.isSupported;

  static String roomIdFor(String communityId, String channelId) =>
      'vc|$communityId|$channelId';

  /// The pair-role rule, pinned pure: for any two digit-strings exactly one
  /// side initiates, both sides agree which, and nobody initiates to
  /// themselves.
  static bool initiates(String myDigits, String otherDigits) =>
      myDigits.compareTo(otherDigits) < 0;

  /// Mesh reconciliation, pure so a test can pin it: who to connect and who
  /// to drop given who presence says is in the room now.
  static ({Set<String> add, Set<String> drop}) diffPeers(
          Set<String> connected, Set<String> present) =>
      (
        add: present.difference(connected),
        drop: connected.difference(present),
      );

  String get _myDigits =>
      (Session.instance.user.value?.phone ?? '').replaceAll(RegExp(r'\D'), '');

  /// Called once at startup: peers follow presence from then on.
  void bind() {
    VoicePresenceStore.instance.addListener(_syncPeers);
  }

  /// Opens the mic and starts connecting to everyone already in the room.
  /// Returns null on success or a human-readable reason (mic permission).
  Future<String?> joinRoom(String communityId, String channelId) async {
    if (!isSupported) return null; // tests / unsupported: silently inert
    final roomId = roomIdFor(communityId, channelId);
    if (_roomId == roomId) return null;
    await leaveRoom();
    try {
      _localStream = await navigator.mediaDevices
          .getUserMedia({'audio': CallQuality.micConstraints()});
    } catch (_) {
      return 'The microphone couldn\'t be opened. Allow microphone access '
          'in iOS Settings and try again.';
    }
    _roomId = roomId;
    _channelId = channelId;
    _syncPeers();
    notifyListeners();
    return null;
  }

  /// Closes every connection and stops every capture.
  Future<void> leaveRoom() async {
    final roomId = _roomId;
    _roomId = null;
    _channelId = null;
    if (roomId != null) {
      for (final digits in _peers.keys) {
        send?.call(digits, roomId: roomId, kind: 'bye');
      }
    }
    for (final pc in _peers.values) {
      try {
        await pc.close();
      } catch (_) {}
    }
    _peers.clear();
    _pendingIce.clear();
    _remoteDescribed.clear();
    for (final r in _remoteRenderers.values) {
      try {
        r.srcObject = null;
        await r.dispose();
      } catch (_) {}
    }
    _remoteRenderers.clear();
    try {
      _screenStream?.getTracks().forEach((t) => t.stop());
      await _screenStream?.dispose();
    } catch (_) {}
    _screenStream = null;
    try {
      _localStream?.getTracks().forEach((t) => t.stop());
      await _localStream?.dispose();
    } catch (_) {}
    _localStream = null;
    try {
      localRenderer?.srcObject = null;
    } catch (_) {}
    cameraOn.value = false;
    screenSharing.value = false;
    notifyListeners();
  }

  /// The renderer showing [digits]'s video, or null when they send none.
  RTCVideoRenderer? rendererFor(String digits) => _remoteRenderers[digits];

  /// Reconciles connections with presence — the mesh follows the room.
  void _syncPeers() {
    final roomId = _roomId;
    final channelId = _channelId;
    if (roomId == null || channelId == null) return;
    // Left the room through ANY door (sign-out included): media follows.
    if (VoicePresenceStore.instance.myChannelId != channelId) {
      unawaited(leaveRoom());
      return;
    }
    final present = <String>{
      for (final o in VoicePresenceStore.instance.occupantsIn(channelId))
        if (!o.isMe && o.digits.isNotEmpty) o.digits
    };
    final diff = diffPeers(_peers.keys.toSet(), present);
    for (final digits in diff.drop) {
      _closePeer(digits);
    }
    for (final digits in diff.add) {
      // Only one side dials; the other hears the offer and answers. The
      // non-initiator creates nothing here — its connection is born in
      // onSignal when the offer arrives.
      if (initiates(_myDigits, digits)) {
        unawaited(_offerTo(digits, roomId));
      }
    }
  }

  Future<RTCPeerConnection> _createPeer(String digits, String roomId) async {
    final pc = await createPeerConnection(CallMedia.rtcConfig);
    _peers[digits] = pc;
    final local = _localStream;
    if (local != null) {
      for (final track in local.getTracks()) {
        await pc.addTrack(track, local);
      }
    }
    // A screen share already running reaches a LATE JOINER too — without
    // this, whoever joined after the share started saw nothing.
    final screen = _screenStream;
    if (screen != null) {
      for (final track in screen.getVideoTracks()) {
        await pc.addTrack(track, screen);
      }
      unawaited(CallQuality.tuneVideoSenders(pc, screen: true));
    }
    pc.onIceCandidate = (candidate) {
      if (candidate.candidate == null) return;
      send?.call(digits, roomId: roomId, kind: 'ice', ice: {
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };
    pc.onTrack = (event) async {
      if (event.streams.isEmpty) return;
      // Deafen holds for people whose audio arrives AFTER the toggle too —
      // otherwise a late joiner talks straight through it.
      if (_deafened && event.track.kind == 'audio') {
        event.track.enabled = false;
      }
      var renderer = _remoteRenderers[digits];
      if (renderer == null) {
        renderer = RTCVideoRenderer();
        await renderer.initialize();
        _remoteRenderers[digits] = renderer;
      }
      renderer.srcObject = event.streams.first;
      notifyListeners();
    };
    return pc;
  }

  Future<void> _offerTo(String digits, String roomId) async {
    if (_peers.containsKey(digits)) return;
    try {
      final pc = await _createPeer(digits, roomId);
      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      final sdp = offer.sdp;
      if (sdp != null) {
        send?.call(digits,
            roomId: roomId, kind: 'offer', sdp: CallQuality.tuneOpus(sdp));
      }
    } catch (_) {
      _closePeer(digits);
    }
  }

  /// One incoming signaling event — wired from the relay.
  Future<void> onSignal(String fromDigits, String roomId, String kind,
      {String? sdp, Map<String, dynamic>? ice}) async {
    if (!isSupported || roomId != _roomId) return;
    try {
      switch (kind) {
        case 'offer':
          if (sdp == null) return;
          // A fresh peer answering, or a live one being renegotiated
          // (their camera / screen coming on) — the same path serves both.
          final pc =
              _peers[fromDigits] ?? await _createPeer(fromDigits, roomId);
          await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
          _remoteDescribed.add(fromDigits);
          final answer = await pc.createAnswer();
          await pc.setLocalDescription(answer);
          await _flushIce(fromDigits, pc);
          final out = answer.sdp;
          if (out != null) {
            send?.call(fromDigits,
                roomId: roomId,
                kind: 'answer',
                sdp: CallQuality.tuneOpus(out));
          }
        case 'answer':
          if (sdp == null) return;
          final pc = _peers[fromDigits];
          if (pc == null) return;
          await pc
              .setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
          _remoteDescribed.add(fromDigits);
          await _flushIce(fromDigits, pc);
        case 'ice':
          if (ice == null) return;
          final pc = _peers[fromDigits];
          if (pc == null || !_remoteDescribed.contains(fromDigits)) {
            // Same race as 1:1 calls: candidates are signaled exactly once,
            // so an early one is queued rather than lost.
            _pendingIce.putIfAbsent(fromDigits, () => []).add(ice);
            return;
          }
          await pc.addCandidate(RTCIceCandidate(
            ice['candidate'] as String?,
            ice['sdpMid'] as String?,
            (ice['sdpMLineIndex'] as num?)?.toInt(),
          ));
        case 'bye':
          _closePeer(fromDigits);
      }
    } catch (_) {}
  }

  Future<void> _flushIce(String digits, RTCPeerConnection pc) async {
    final queued = _pendingIce.remove(digits) ?? const [];
    for (final c in queued) {
      try {
        await pc.addCandidate(RTCIceCandidate(
          c['candidate'] as String?,
          c['sdpMid'] as String?,
          (c['sdpMLineIndex'] as num?)?.toInt(),
        ));
      } catch (_) {}
    }
  }

  void _closePeer(String digits) {
    final pc = _peers.remove(digits);
    if (pc != null) {
      unawaited(pc.close().catchError((_) {}));
    }
    _pendingIce.remove(digits);
    _remoteDescribed.remove(digits);
    final renderer = _remoteRenderers.remove(digits);
    if (renderer != null) {
      try {
        renderer.srcObject = null;
        unawaited(renderer.dispose());
      } catch (_) {}
    }
    notifyListeners();
  }

  /// Mutes/unmutes the mic across every connection at once.
  void setMuted(bool muted) {
    _localStream?.getAudioTracks().forEach((t) => t.enabled = !muted);
  }

  /// Deafen: stop PLAYING everyone. Their audio tracks are disabled on the
  /// receive side; the connections stay up so undeafening is instant.
  void setDeafened(bool deafened) {
    for (final renderer in _remoteRenderers.values) {
      final stream = renderer.srcObject;
      if (stream == null) continue;
      for (final t in stream.getAudioTracks()) {
        t.enabled = !deafened;
      }
    }
    _deafened = deafened;
  }

  bool _deafened = false;

  Future<void> _ensureLocalRenderer() async {
    if (localRenderer != null) return;
    localRenderer = RTCVideoRenderer();
    await localRenderer!.initialize();
  }

  /// Turns the camera on/off for the whole room. Adding a first-ever video
  /// track renegotiates every connection — this side offers, whatever the
  /// pair's original roles were, because it is the one whose media changed.
  Future<void> enableCamera(bool on) async {
    if (!isSupported || _roomId == null) return;
    try {
      final existing = _localStream?.getVideoTracks() ?? [];
      if (!on) {
        for (final t in existing) {
          t.enabled = false;
        }
        cameraOn.value = false;
        return;
      }
      if (existing.isNotEmpty) {
        for (final t in existing) {
          t.enabled = true;
        }
        cameraOn.value = true;
        return;
      }
      final cam = await navigator.mediaDevices
          .getUserMedia({'video': CallQuality.cameraConstraints()});
      final track = cam.getVideoTracks().first;
      final local = _localStream;
      if (local == null) return;
      await local.addTrack(track);
      await _ensureLocalRenderer();
      if (!screenSharing.value) localRenderer!.srcObject = local;
      for (final entry in _peers.entries) {
        await entry.value.addTrack(track, local);
        unawaited(
            CallQuality.tuneVideoSenders(entry.value, screen: false));
        await _renegotiate(entry.key, entry.value);
      }
      cameraOn.value = true;
      notifyListeners();
    } catch (_) {}
  }

  /// Shares this screen into the room, swapping it onto every connection's
  /// video sender (or adding one where the pair was audio-only). Returns
  /// null on success or a human-readable reason.
  Future<String?> toggleScreenShare() async {
    if (!isSupported || _roomId == null) return 'Not connected to voice.';
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
      for (final entry in _peers.entries) {
        final senders = await entry.value.getSenders();
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
          await entry.value.addTrack(track, display);
          await _renegotiate(entry.key, entry.value);
        }
        unawaited(CallQuality.tuneVideoSenders(entry.value, screen: true));
      }
      await _ensureLocalRenderer();
      localRenderer!.srcObject = display;
      track.onEnded = () => _stopScreenShare();
      _screenStream = display;
      screenSharing.value = true;
      notifyListeners();
      return null;
    } catch (_) {
      return kIsWeb
          ? 'Screen sharing isn\'t available in this browser.'
          : 'Screen sharing couldn\'t start. If iOS asked to record the '
              'screen, it needs to be allowed.';
    }
  }

  Future<void> _stopScreenShare() async {
    try {
      _screenStream?.getTracks().forEach((t) => t.stop());
      await _screenStream?.dispose();
    } catch (_) {}
    _screenStream = null;
    screenSharing.value = false;
    try {
      final cam = _localStream?.getVideoTracks() ?? [];
      for (final pc in _peers.values) {
        final senders = await pc.getSenders();
        for (final s in senders) {
          if (s.track?.kind == 'video' && cam.isNotEmpty) {
            await s.replaceTrack(cam.first);
          }
        }
        unawaited(CallQuality.tuneVideoSenders(pc, screen: false));
      }
      if (cameraOn.value && _localStream != null) {
        localRenderer?.srcObject = _localStream;
      } else {
        localRenderer?.srcObject = null;
      }
    } catch (_) {}
    notifyListeners();
  }

  /// A fresh offer/answer round on a live connection, after this side's
  /// media changed. The far side answers through the same 'offer' path a
  /// new connection uses.
  Future<void> _renegotiate(String digits, RTCPeerConnection pc) async {
    final roomId = _roomId;
    if (roomId == null) return;
    try {
      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      final sdp = offer.sdp;
      if (sdp != null) {
        send?.call(digits,
            roomId: roomId, kind: 'offer', sdp: CallQuality.tuneOpus(sdp));
      }
    } catch (_) {}
  }

  /// Whether the room currently plays audio to this device — the deafen
  /// state applied to tracks that arrive AFTER the toggle too.
  bool get deafened => _deafened;

  @visibleForTesting
  void resetForTest() {
    _peers.clear();
    _pendingIce.clear();
    _remoteDescribed.clear();
    _remoteRenderers.clear();
    _roomId = null;
    _channelId = null;
    _localStream = null;
    _screenStream = null;
    _deafened = false;
    cameraOn.value = false;
    screenSharing.value = false;
    send = null;
    notifyListeners();
  }
}
