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

  /// A ringing group call's room — same mesh, roster fed by CallService
  /// instead of channel presence.
  static String roomIdForCall(String callId) => 'gc|$callId';

  /// Non-null while the mesh is serving a GROUP CALL: the joined members'
  /// digits, updated by CallService as joins and leaves arrive. Voice
  /// channels leave this null and follow presence instead.
  Set<String>? _explicitPeers;

  /// The mesh's honest ceiling. Every member sends to every other, so a
  /// room of N costs each phone N-1 encodes of everything — at eight that
  /// is already a hot phone, and past it the room degrades for EVERYONE,
  /// not just the weakest device. Discord holds bigger rooms with a media
  /// server; this app keeps media end-to-end instead, and says the price
  /// out loud rather than melting quietly.
  static const int maxRoomSize = 8;

  /// The legs this device should hold, given who presence shows: everyone,
  /// up to the cap — and when the room is over it, the FIRST [maxRoomSize]
  /// occupants by digit-sort, so every member picks the same subset instead
  /// of each connecting to a different eight. Pure, so a test can pin it.
  static Set<String> legsFor(Set<String> present, String myDigits,
      {int cap = maxRoomSize}) {
    final everyone = {...present, myDigits}.toList()..sort();
    final room = everyone.take(cap).toSet();
    if (!room.contains(myDigits)) return const {};
    room.remove(myDigits);
    return room;
  }

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
    final roomId = roomIdFor(communityId, channelId);
    if (_roomId == roomId) return null;
    // Full is full, said before the mic opens: joining voice in a room
    // already at the mesh's ceiling would mean sitting in silence while
    // appearing connected.
    final inVoice = VoicePresenceStore.instance.countIn(channelId);
    if (inVoice >= maxRoomSize) {
      return 'This room is full for voice — device-to-device audio holds '
          '$maxRoomSize people. You can still read the channel; a spot '
          'opens when somebody leaves.';
    }
    return _openRoom(roomId, channelId: channelId, speaker: true);
  }

  /// The same mesh serving a GROUP CALL: the roster is whoever CallService
  /// says has joined, updated by [updateCallPeers] as the call moves.
  /// [speaker] follows the call's shape — video calls are held at arm's
  /// length, voice calls at the ear.
  Future<String?> joinCall(String callId, Set<String> peerDigits,
      {required bool speaker}) async {
    final roomId = roomIdForCall(callId);
    if (_roomId == roomId) return null;
    return _openRoom(roomId,
        explicitPeers: peerDigits, speaker: speaker);
  }

  /// CallService's join/leave bookkeeping reaching the mesh. A no-op
  /// outside call mode, so a stray late event cannot touch a voice channel.
  void updateCallPeers(String callId, Set<String> peerDigits) {
    if (_roomId != roomIdForCall(callId) || _explicitPeers == null) return;
    _explicitPeers = Set.of(peerDigits);
    _syncPeers();
  }

  /// Tears the mesh down only when it is serving [callId] — the group call
  /// ending must never take down a voice channel joined since.
  Future<void> leaveCall(String callId) async {
    if (_roomId == roomIdForCall(callId)) await leaveRoom();
  }

  Future<String?> _openRoom(String roomId,
      {String? channelId,
      Set<String>? explicitPeers,
      required bool speaker}) async {
    if (!isSupported) return null; // tests / unsupported: silently inert
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
    _explicitPeers = explicitPeers == null ? null : Set.of(explicitPeers);
    // A room plays out of the SPEAKER, like Discord — a voice channel held
    // to your ear is a phone call pretending. A group VOICE call stays at
    // the ear, like any call.
    unawaited(CallQuality.configureAudioSession(speaker: speaker));
    _syncPeers();
    _startVoiceMeter();
    notifyListeners();
    return null;
  }

  // --- Speaking detection ------------------------------------------------
  // The green ring used to mean "not muted", which is as much as presence
  // alone could claim. With media flowing the stats know who is actually
  // making sound, so the ring can mean what everyone assumes it means.

  Timer? _voiceTimer;
  final Map<String, DateTime> _lastAudible = {};
  DateTime? _meLastAudible;
  Set<String> _speakingNow = const {};
  bool _meSpeakingNow = false;
  int _meterTick = 0;
  final Map<String, int> _lastLost = {};
  final Map<String, int> _lastReceived = {};
  final Map<String, AdaptiveBitrate> _abrByPeer = {};

  /// The room's link, as bars: the WORST leg decides (3 good … 1 poor,
  /// 0 unknown) — a mesh is only as good as the leg you can't hear.
  final ValueNotifier<int> roomQuality = ValueNotifier<int>(0);

  /// How long the ring lingers after the last audible sample — the gap
  /// between two words must not flicker it off.
  static const Duration _speechHold = Duration(milliseconds: 900);

  /// Whether [digits] was audibly speaking within the hold window.
  bool isSpeaking(String digits) => _speakingNow.contains(digits);

  /// Whether this device's own mic is audibly live.
  bool get amSpeaking => _meSpeakingNow;

  void _startVoiceMeter() {
    _voiceTimer?.cancel();
    _voiceTimer = Timer.periodic(
        const Duration(milliseconds: 700), (_) => _sampleVoice());
  }

  Future<void> _sampleVoice() async {
    if (_roomId == null) return;
    final now = DateTime.now();
    // Loss over 700 ms is noise; judge links on a ~3 s window instead.
    _meterTick += 1;
    final judgeLinks = _meterTick % 4 == 0;
    var worst = 0;
    var sampledLocal = false;
    for (final entry in _peers.entries) {
      try {
        final reports = await entry.value.getStats();
        var lost = 0;
        var received = 0;
        double? rttMs;
        for (final r in reports) {
          if (r.type == 'candidate-pair') {
            final rtt =
                (r.values['currentRoundTripTime'] as num?)?.toDouble();
            if (rtt != null && rtt > 0) {
              final ms = rtt * 1000;
              rttMs = rttMs == null || ms > rttMs ? ms : rttMs;
            }
            continue;
          }
          if (r.type == 'inbound-rtp') {
            lost += (r.values['packetsLost'] as num?)?.toInt() ?? 0;
            received +=
                (r.values['packetsReceived'] as num?)?.toInt() ?? 0;
          }
          final kind =
              (r.values['kind'] ?? r.values['mediaType'])?.toString();
          if (kind != 'audio') continue;
          final level = (r.values['audioLevel'] as num?)?.toDouble();
          if (r.type == 'inbound-rtp' && CallQuality.audible(level)) {
            _lastAudible[entry.key] = now;
          }
          // The local mic's level shows up once per connection; one
          // sample of it is plenty.
          if (r.type == 'media-source' && !sampledLocal) {
            sampledLocal = true;
            if (CallQuality.audible(level)) _meLastAudible = now;
          }
        }
        if (judgeLinks) {
          final dLost =
              (lost - (_lastLost[entry.key] ?? 0)).clamp(0, 1 << 30);
          final dReceived = (received - (_lastReceived[entry.key] ?? 0))
              .clamp(0, 1 << 30);
          _lastLost[entry.key] = lost;
          _lastReceived[entry.key] = received;
          final total = dLost + dReceived;
          if (total > 0) {
            final loss = dLost / total;
            final q = CallMedia.qualityFor(loss, rttMs: rttMs);
            worst = worst == 0 || q < worst ? q : worst;
            // Each leg's video cap follows ITS link — the weak leg backs
            // off without dragging the strong ones down with it.
            if (cameraOn.value || screenSharing.value) {
              final abr = _abrByPeer.putIfAbsent(
                  entry.key,
                  () => AdaptiveBitrate(
                      floor: 250000, ceiling: 2500000, start: 1200000));
              if (abr.sample(loss)) {
                unawaited(CallQuality.tuneVideoSenders(entry.value,
                    screen: screenSharing.value, bitrateOverride: abr.rate));
              }
            }
          }
        }
      } catch (_) {}
    }
    if (judgeLinks && _peers.isNotEmpty) roomQuality.value = worst;
    final speaking = <String>{
      for (final e in _lastAudible.entries)
        if (now.difference(e.value) < _speechHold) e.key
    };
    final me = _meLastAudible != null &&
        now.difference(_meLastAudible!) < _speechHold;
    if (!setEquals(speaking, _speakingNow) || me != _meSpeakingNow) {
      _speakingNow = speaking;
      _meSpeakingNow = me;
      notifyListeners();
    }
  }

  /// Closes every connection and stops every capture.
  Future<void> leaveRoom() async {
    final roomId = _roomId;
    _roomId = null;
    _channelId = null;
    _explicitPeers = null;
    _voiceTimer?.cancel();
    _voiceTimer = null;
    _lastAudible.clear();
    _lastRestart.clear();
    _lastLost.clear();
    _lastReceived.clear();
    _abrByPeer.clear();
    _meterTick = 0;
    roomQuality.value = 0;
    _meLastAudible = null;
    _speakingNow = const {};
    _meSpeakingNow = false;
    shareFailure.value = null;
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

  /// Reconciles connections with the roster — presence for a voice
  /// channel, CallService's joined list for a group call. The mesh follows
  /// the room either way.
  void _syncPeers() {
    final roomId = _roomId;
    if (roomId == null) return;
    final Set<String> present;
    final explicit = _explicitPeers;
    if (explicit != null) {
      present = explicit;
    } else {
      final channelId = _channelId;
      if (channelId == null) return;
      // Left the room through ANY door (sign-out included): media follows.
      if (VoicePresenceStore.instance.myChannelId != channelId) {
        unawaited(leaveRoom());
        return;
      }
      present = <String>{
        for (final o in VoicePresenceStore.instance.occupantsIn(channelId))
          if (!o.isMe && o.digits.isNotEmpty) o.digits
      };
    }
    // The cap, applied the same way on every device: an over-full room
    // meshes its first eight by digit-sort and carries the rest as
    // presence only, instead of every phone melting a different way.
    final wanted = legsFor(present, _myDigits);
    final diff = diffPeers(_peers.keys.toSet(), wanted);
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
    final pc =
        await createPeerConnection(await CallMedia.resolvedRtcConfig());
    _peers[digits] = pc;
    // A network switch kills every negotiated pair; the pair's INITIATOR
    // redials with fresh ICE credentials over the same offer path. The
    // other side just answers — a failure both notice at once must not
    // produce colliding offers.
    pc.onConnectionState = (state) {
      if (state !=
          RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        return;
      }
      if (initiates(_myDigits, digits)) {
        final last = _lastRestart[digits];
        if (last != null &&
            DateTime.now().difference(last) < const Duration(seconds: 8)) {
          return;
        }
        _lastRestart[digits] = DateTime.now();
        unawaited(_restartPeer(digits, pc, roomId));
      }
    };
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
        case 'renegreq':
          // The non-initiator's media changed; this side owns the offer.
          final pc = _peers[fromDigits];
          if (pc != null && initiates(_myDigits, fromDigits)) {
            await _renegotiate(fromDigits, pc);
          }
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
    _lastLost.remove(digits);
    _lastReceived.remove(digits);
    _abrByPeer.remove(digits);
    _lastAudible.remove(digits);
    _lastRestart.remove(digits);
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
      shareFailure.value = null;
      unawaited(_verifyShareMovesFrames());
      notifyListeners();
      return null;
    } catch (_) {
      return kIsWeb
          ? 'Screen sharing isn\'t available in this browser.'
          : 'Screen sharing couldn\'t start. If iOS asked to record the '
              'screen, it needs to be allowed.';
    }
  }

  /// Set when a room screen share started and then visibly produced
  /// NOTHING — everyone else was watching a black rectangle while this
  /// side showed "sharing". The room screen surfaces it; the share is
  /// already stopped. Same failure, same honesty as the 1:1 call's check.
  final ValueNotifier<String?> shareFailure = ValueNotifier<String?>(null);

  /// Cumulative outbound video frames across every leg, or -1 with none.
  Future<int> _outboundVideoFrames() async {
    var total = -1;
    for (final pc in _peers.values) {
      try {
        final reports = await pc.getStats();
        for (final r in reports) {
          if (r.type != 'outbound-rtp') continue;
          final kind =
              (r.values['kind'] ?? r.values['mediaType'])?.toString();
          if (kind != 'video') continue;
          final n = (r.values['framesEncoded'] as num?)?.toInt() ?? 0;
          total = total == -1 ? n : total + n;
        }
      } catch (_) {}
    }
    return total;
  }

  /// Proves the room share is actually moving pictures — iOS's in-app
  /// capture can start "successfully" and deliver zero frames (a denied
  /// recording permission, a Screen Time block), and the only symptom is
  /// a black tile on everyone else's screen.
  Future<void> _verifyShareMovesFrames() async {
    final before = await _outboundVideoFrames();
    await Future<void>.delayed(const Duration(seconds: 6));
    if (!screenSharing.value || _roomId == null) return;
    final after = await _outboundVideoFrames();
    if (after > before) return; // pictures are flowing
    await _stopScreenShare();
    shareFailure.value =
        'Screen sharing produced no picture, so it was stopped. iOS may '
        'have refused screen recording — try again and allow it (and check '
        'Settings → Screen Time → Content & Privacy restrictions).';
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

  final Map<String, DateTime> _lastRestart = {};

  /// An ICE-restart round for one dead pair — new credentials, same
  /// signaling path, connection object kept.
  Future<void> _restartPeer(
      String digits, RTCPeerConnection pc, String roomId) async {
    try {
      final offer = await pc.createOffer({'iceRestart': true});
      await pc.setLocalDescription(offer);
      final sdp = offer.sdp;
      if (sdp != null) {
        send?.call(digits,
            roomId: roomId, kind: 'offer', sdp: CallQuality.tuneOpus(sdp));
      }
    } catch (_) {}
  }

  /// A fresh offer/answer round on a live connection, after this side's
  /// media changed. GLARE-FREE by construction: only the pair's fixed
  /// initiator ever creates offers. When the OTHER side's media changes it
  /// asks for a round ('renegreq') and the initiator offers — one round
  /// renegotiates both directions, so the asker's new track rides back in
  /// the answer. Two people turning cameras on at the same instant
  /// therefore cannot collide head-on, which a both-sides-offer scheme
  /// lets happen exactly then.
  Future<void> _renegotiate(String digits, RTCPeerConnection pc) async {
    final roomId = _roomId;
    if (roomId == null) return;
    if (!initiates(_myDigits, digits)) {
      send?.call(digits, roomId: roomId, kind: 'renegreq');
      return;
    }
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
    _voiceTimer?.cancel();
    _voiceTimer = null;
    _lastAudible.clear();
    _lastRestart.clear();
    _lastLost.clear();
    _lastReceived.clear();
    _abrByPeer.clear();
    _meterTick = 0;
    roomQuality.value = 0;
    _meLastAudible = null;
    _speakingNow = const {};
    _meSpeakingNow = false;
    _roomId = null;
    _channelId = null;
    _explicitPeers = null;
    _localStream = null;
    _screenStream = null;
    _deafened = false;
    cameraOn.value = false;
    screenSharing.value = false;
    send = null;
    notifyListeners();
  }
}
