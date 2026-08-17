import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../relay/relay_service.dart';
import '../relay/turn_service.dart';
import 'call_quality.dart';

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

  /// Set when the media path has negotiated for so long that waiting is no
  /// longer the plan — with WHERE to look, because "Connecting…" forever
  /// was this app's most opaque failure until the call self-test existed.
  final ValueNotifier<bool> connectStalled = ValueNotifier<bool>(false);
  Timer? _stallTimer;

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
  /// The ICE configuration, shared with the voice-channel mesh so both ride
  /// the same STUN/TURN path — a room leg behind carrier NAT needs the
  /// relay exactly as much as a 1:1 call does.
  static Map<String, dynamic> get rtcConfig => _config;

  /// The config a call should actually use: the static base plus whatever
  /// relay credentials the `turn-credentials` function hands out. The
  /// fetch fails open and is cached, so this is never slower than one
  /// short request and never worse than the static config.
  static Future<Map<String, dynamic>> resolvedRtcConfig() async =>
      mergeIce(rtcConfig, await TurnService.iceServers());

  /// Base + extra ice servers, extras FIRST so a working relay is tried
  /// before the dead public one. Pure, so a test can pin it.
  static Map<String, dynamic> mergeIce(
      Map<String, dynamic> base, List<Map<String, dynamic>> extra) {
    if (extra.isEmpty) return base;
    return {
      ...base,
      'iceServers': [...extra, ...(base['iceServers'] as List)],
    };
  }

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
            {
              // TCP on 443 for the networks that swallow UDP entirely —
              // hotel and office firewalls. Worse latency than UDP relay,
              // but a call that connects at 250 ms beats one that doesn't.
              'urls': 'turn:openrelay.metered.ca:443?transport=tcp',
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
    final pc = await createPeerConnection(await resolvedRtcConfig());
    _pc = pc;
    // The full processed-mic chain and a bounded 720p30 camera — the same
    // profile the voice-channel mesh uses, from the one place it lives.
    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': CallQuality.micConstraints(),
      'video': video ? CallQuality.cameraConstraints() : false,
    });
    localRenderer!.srcObject = _localStream;
    // Apple's own call-audio pipeline under WebRTC's: voiceChat to the
    // earpiece for a voice call, videoChat to the speaker for video.
    unawaited(CallQuality.configureAudioSession(speaker: video));
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
      if (connectionState.value == 'connected') {
        _stallTimer?.cancel();
        connectStalled.value = false;
      }
      _watchForDeadLink(connectionState.value);
    };
    connectionState.value = 'connecting';
    _stallTimer?.cancel();
    _stallTimer = Timer(const Duration(seconds: 25), () {
      final s = connectionState.value;
      if (s == 'new' || s == 'connecting') connectStalled.value = true;
    });
    localVideo.value = video;
    if (video) {
      unawaited(CallQuality.tuneVideoSenders(pc, screen: false));
    }
    _startStatsMonitor();
  }

  /// Caller side: opens the mic/camera and returns the SDP offer to signal.
  Future<String?> createOffer(String peerPhone, bool video) async {
    if (!isSupported) return null;
    try {
      await _createPeer(peerPhone, video);
      final offer = await _pc!.createOffer();
      await _pc!.setLocalDescription(offer);
      // Tune the STRING we signal, never the local description: the fmtp in
      // an offer tells the far side how to encode toward us.
      return offer.sdp == null ? null : CallQuality.tuneOpus(offer.sdp!);
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
      return answer.sdp == null ? null : CallQuality.tuneOpus(answer.sdp!);
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

  // --- ICE restart: surviving a network switch ---------------------------
  // Walking out of Wi-Fi coverage mid-call moves the phone to cellular and
  // every negotiated ICE pair dies with the old address. Without a restart
  // the call sat in "Reconnecting…" until somebody gave up. An ICE restart
  // is a renegotiation offer with fresh credentials — it rides the exact
  // path a camera-on offer already rides, and the far side answers in place.

  /// Fired when the connection failed (or stayed disconnected long enough
  /// to mean it) and a restart offer should be signaled. Wired to
  /// CallService at startup; null in tests.
  void Function()? onNeedsIceRestart;

  Timer? _disconnectTimer;
  DateTime? _lastRestartAsk;

  void _watchForDeadLink(String state) {
    if (state == 'failed') {
      _disconnectTimer?.cancel();
      _askRestart();
    } else if (state == 'disconnected') {
      // Disconnected often self-heals in a second or two; only a persistent
      // one is worth a restart round.
      _disconnectTimer?.cancel();
      _disconnectTimer = Timer(const Duration(seconds: 5), () {
        if (connectionState.value == 'disconnected') _askRestart();
      });
    } else {
      _disconnectTimer?.cancel();
    }
  }

  void _askRestart() {
    final now = DateTime.now();
    // One ask per window — a flapping link must not stack offers.
    if (_lastRestartAsk != null &&
        now.difference(_lastRestartAsk!) < const Duration(seconds: 8)) {
      return;
    }
    _lastRestartAsk = now;
    onNeedsIceRestart?.call();
  }

  /// A renegotiation offer with fresh ICE credentials.
  Future<String?> createIceRestartOffer() async {
    if (!isSupported || _pc == null) return null;
    try {
      final offer = await _pc!.createOffer({'iceRestart': true});
      await _pc!.setLocalDescription(offer);
      return offer.sdp == null ? null : CallQuality.tuneOpus(offer.sdp!);
    } catch (_) {
      return null;
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
      return offer.sdp == null ? null : CallQuality.tuneOpus(offer.sdp!);
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
      return answer.sdp == null ? null : CallQuality.tuneOpus(answer.sdp!);
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
        'video': CallQuality.cameraConstraints(),
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
      if (_pc != null) {
        unawaited(CallQuality.tuneVideoSenders(_pc!, screen: false));
      }
      // A voice call growing a camera becomes a video call — speaker too.
      unawaited(CallQuality.configureAudioSession(speaker: true));
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
      // Detail over motion: hold resolution so shared text stays readable,
      // and let the frame rate fall instead.
      unawaited(CallQuality.tuneVideoSenders(_pc!, screen: true));
      // The browser's own "Stop sharing" bar ends the track — follow it.
      track.onEnded = () => _stopScreenShare();
      _screenStream = display;
      screenSharing.value = true;
      shareFailure.value = null;
      unawaited(_verifyShareMovesFrames());
      return null;
    } catch (_) {
      // Say the failure the PLATFORM actually has. On the phone it is a
      // permission (or ReplayKit being unavailable); the browser sentence
      // on an iPhone app read as "this feature is fake".
      return kIsWeb
          ? 'Screen sharing isn\'t available in this browser — iPhone '
              'Safari doesn\'t allow web screen capture; Android Chrome and '
              'desktop browsers do.'
          : 'Screen sharing couldn\'t start. If iOS asked to record the '
              'screen, it needs to be allowed.';
    }
  }

  /// Set when screen sharing started and then visibly produced NOTHING —
  /// the far end was seeing a black rectangle while this side showed
  /// "sharing". The UI surfaces it; the share is already stopped.
  final ValueNotifier<String?> shareFailure = ValueNotifier<String?>(null);

  /// Cumulative outbound video frames encoded, or -1 when there is no video
  /// sender to read.
  Future<int> _outboundVideoFrames() async {
    final pc = _pc;
    if (pc == null) return -1;
    try {
      final reports = await pc.getStats();
      for (final r in reports) {
        if (r.type != 'outbound-rtp') continue;
        final kind =
            (r.values['kind'] ?? r.values['mediaType'])?.toString();
        if (kind != 'video') continue;
        return (r.values['framesEncoded'] as num?)?.toInt() ?? 0;
      }
    } catch (_) {}
    return -1;
  }

  /// Proves the share is actually moving pictures. iOS's in-app capture can
  /// start "successfully" and deliver zero frames — a denied recording
  /// permission or a Screen Time block — and the only symptom is a black
  /// rectangle on the far end. Compare the encoder's frame count across a
  /// few seconds; if it did not move, stop the share and say why. The DELTA
  /// matters: on a video call the counter already includes camera frames.
  Future<void> _verifyShareMovesFrames() async {
    final before = await _outboundVideoFrames();
    await Future<void>.delayed(const Duration(seconds: 6));
    if (!screenSharing.value || _pc == null) return;
    final after = await _outboundVideoFrames();
    if (after > before) return; // pictures are flowing
    await _stopScreenShare();
    shareFailure.value = screenShareNoPictureMessage;
  }

  /// What to say when the share started and no frame ever moved.
  ///
  /// The old wording blamed a denied permission and sent people to Screen
  /// Time. That is ONE cause and usually not the one: on iPhone this path is
  /// ReplayKit's in-app recorder, and the plugin swallows every way it can
  /// fail — if the recorder is unavailable it logs and returns, and if
  /// `startCaptureWithHandler` errors it logs and returns. Either way Dart is
  /// handed a track that looks alive and never produces a picture, so the app
  /// CANNOT tell which happened. Saying "allow the permission" to somebody
  /// whose permission was never the problem sends them hunting through
  /// Settings for something that was never switched off.
  ///
  /// So: name the two real possibilities, and say plainly that screen sharing
  /// on iPhone is unreliable here rather than implying they have misconfigured
  /// their phone.
  static const String screenShareNoPictureMessage =
      'Screen sharing started but never sent a picture, so it was stopped. '
      'On iPhone this is usually iOS refusing to record during a call, not '
      'anything you did. Worth trying once more; if it fails again, share '
      'from a computer instead. (If you have Screen Recording switched off '
      'in Settings → Screen Time → Content & Privacy, that would also do it.)';

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
      if (_pc != null) {
        // Back to motion-first now the camera is on the wire again.
        unawaited(CallQuality.tuneVideoSenders(_pc!, screen: false));
      }
      if (_localStream != null) localRenderer?.srcObject = _localStream;
    } catch (_) {}
  }

  /// True while the call is on hold (nothing sent, nothing played).
  final ValueNotifier<bool> onHold = ValueNotifier<bool>(false);

  /// Link quality from live WebRTC stats: 3 = good, 2 = fair, 1 = poor,
  /// 0 = unknown/no data yet. Drives the signal bars on the call screen.
  final ValueNotifier<int> quality = ValueNotifier<int>(0);

  /// The video ceiling while the TURN relay is carrying the call.
  ///
  /// A relayed byte is a byte somebody pays for, and video is the whole bill:
  /// audio is tens of kilobits a second, video at the normal 2.5 Mbit ceiling
  /// is roughly forty times that. Holding relayed video here cuts what the
  /// relay carries by about four times against the normal ceiling, and it is
  /// still a perfectly watchable call — the alternative people reach for is
  /// turning the relay off, which does not save money so much as stop calls
  /// connecting at all whenever both ends sit behind carrier NAT.
  ///
  /// Deliberately above [AdaptiveBitrate.floor], so the link's own congestion
  /// control still has room to move underneath it.
  static const int relayVideoBitrate = 600000;

  /// Which path the call actually took: '' unknown, 'direct', or 'relay'
  /// (through the TURN server). Surfaced on the call screen because "is
  /// this call going through Metered" is otherwise answerable only from
  /// Metered's own usage graph, hours later.
  final ValueNotifier<String> mediaPath = ValueNotifier<String>('');

  /// The local candidate type of the SELECTED pair, from raw stats tuples
  /// (type, id, values). Pure, so a test can pin the selection order:
  /// the transport's chosen pair first, then a nominated succeeded pair,
  /// then any succeeded pair.
  static String? selectedLocalType(
      List<(String, String, Map<dynamic, dynamic>)> reports) {
    final localTypes = <String, String>{};
    final pairs = <String, Map<dynamic, dynamic>>{};
    String? selectedPairId;
    for (final (type, id, values) in reports) {
      if (type == 'local-candidate') {
        final ct = values['candidateType']?.toString();
        if (ct != null) localTypes[id] = ct;
      } else if (type == 'candidate-pair') {
        pairs[id] = values;
      } else if (type == 'transport') {
        selectedPairId ??= values['selectedCandidatePairId']?.toString();
      }
    }
    Map<dynamic, dynamic>? chosen =
        selectedPairId == null ? null : pairs[selectedPairId];
    chosen ??= pairs.values
        .where((p) =>
            p['nominated'] == true && p['state']?.toString() == 'succeeded')
        .cast<Map<dynamic, dynamic>?>()
        .firstOrNull;
    // Neither the transport nor nomination answered — and BOTH are optional in
    // practice, so this branch is reached on real devices rather than being
    // theoretical. "Any succeeded pair" was the old answer and it is a coin
    // toss: a direct call very often ALSO has a succeeded relay pair sitting
    // beside the host one, and picking from an arbitrary map order reports
    // "via relay" for a call going straight out. So prefer the pair actually
    // CARRYING the media — the one with traffic on it.
    if (chosen == null) {
      final succeeded = pairs.values
          .where((p) => p['state']?.toString() == 'succeeded')
          .toList();
      num bytes(Map<dynamic, dynamic> p) =>
          ((p['bytesReceived'] as num?) ?? 0) + ((p['bytesSent'] as num?) ?? 0);
      succeeded.sort((a, b) => bytes(b).compareTo(bytes(a)));
      // Still nothing moving on any of them (the first seconds of a call, or a
      // platform that does not report byte counts) — fall back to the old
      // answer rather than to none.
      chosen = succeeded.cast<Map<dynamic, dynamic>?>().firstOrNull;
    }
    if (chosen == null) return null;
    final localId = chosen['localCandidateId']?.toString();
    return localId == null ? null : localTypes[localId];
  }

  Timer? _statsTimer;
  int _lastLost = 0;
  int _lastReceived = 0;
  AdaptiveBitrate? _abr;

  /// Maps a packet-loss ratio to quality bars. Pure, so it's easy to test.
  static int qualityForLoss(double lossRatio) {
    if (lossRatio >= 0.08) return 1; // audible dropouts
    if (lossRatio >= 0.02) return 2; // noticeable but usable
    return 3;
  }

  /// Bars from loss AND round-trip time — the worse of the two. A lossless
  /// link at 500 ms is still a bad phone call, and loss alone called it
  /// perfect. Pure, so it's easy to test.
  static int qualityFor(double lossRatio, {double? rttMs}) {
    final byLoss = qualityForLoss(lossRatio);
    final byRtt = rttMs == null
        ? 3
        : rttMs >= 400
            ? 1
            : rttMs >= 250
                ? 2
                : 3;
    return byLoss < byRtt ? byLoss : byRtt;
  }

  /// Polls the peer connection for inbound packet loss while a call runs.
  void _startStatsMonitor() {
    _statsTimer?.cancel();
    _lastLost = 0;
    _lastReceived = 0;
    // Bounds wide enough for both cargos; what the cap protects is the
    // LINK, and the link doesn't care whether the pixels are a face or a
    // spreadsheet.
    _abr = AdaptiveBitrate(floor: 250000, ceiling: 2500000, start: 1200000);
    _statsTimer =
        Timer.periodic(const Duration(seconds: 3), (_) => _sampleStats());
  }

  Future<void> _sampleStats() async {
    final pc = _pc;
    if (pc == null) return;
    try {
      final reports = await pc.getStats();
      // Which path the call took, refreshed live — an ICE restart mid-call
      // can move a direct call onto the relay and back.
      final local = selectedLocalType([
        for (final r in reports) (r.type, r.id, r.values),
      ]);
      if (local != null) {
        mediaPath.value = local == 'relay' ? 'relay' : 'direct';
      }
      var lost = 0;
      var received = 0;
      double? rttMs;
      for (final r in reports) {
        if (r.type == 'candidate-pair') {
          final rtt = (r.values['currentRoundTripTime'] as num?)?.toDouble();
          if (rtt != null && rtt > 0) {
            final ms = rtt * 1000;
            rttMs = rttMs == null || ms > rttMs ? ms : rttMs;
          }
          continue;
        }
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
      final loss = dLost / total;
      quality.value = qualityFor(loss, rttMs: rttMs);
      // The adaptive cap: only worth applying while video is on the wire.
      final abr = _abr;
      if (abr != null && (hasLocalVideo || screenSharing.value)) {
        // A RELAYED call is billed by the byte, so video on it is held to a
        // much lower cap than the link could carry. Re-checked every sample
        // rather than set once: an ICE restart mid-call can move a direct
        // call onto the relay and back, and the cap has to follow it both
        // ways. Both calls run — `||` would short-circuit `sample` and stop
        // the link adapting the moment the cap was in force.
        final capped = abr.setLimit(mediaPath.value == 'relay'
            ? relayVideoBitrate
            : abr.ceiling);
        final adapted = abr.sample(loss);
        if (capped || adapted) {
          unawaited(CallQuality.tuneVideoSenders(pc,
              screen: screenSharing.value, bitrateOverride: abr.rate));
        }
      }
    } catch (_) {
      // Stats are unavailable on some platforms; leave the last reading.
    }
  }

  /// Holds/resumes the call: stops sending audio and video, and silences
  /// the incoming stream, without tearing the connection down.
  void setHold(bool held) {
    onHold.value = held;
    _localStream?.getTracks().forEach((t) => t.enabled = !held);
    // Silence what ARRIVES by disabling the remote tracks themselves.
    // `renderer.muted` is a web semantic — on the phone, remote audio
    // plays through the audio session with or without a renderer, which
    // is why hold used to mute you and leave them perfectly audible.
    try {
      final remote = remoteRenderer?.srcObject;
      remote?.getAudioTracks().forEach((t) => t.enabled = !held);
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
    _abr = null;
    _disconnectTimer?.cancel();
    _disconnectTimer = null;
    _stallTimer?.cancel();
    _stallTimer = null;
    connectStalled.value = false;
    _lastRestartAsk = null;
    quality.value = 0;
    mediaPath.value = '';
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
