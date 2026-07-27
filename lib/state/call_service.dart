import 'dart:async';

import 'package:flutter/foundation.dart';

import '../app_state.dart';
import '../models/call.dart' as log;
import '../models/chat.dart';
import '../models/message.dart';
import '../models/user.dart';
import '../relay/relay_config.dart';
import '../relay/relay_service.dart';
import 'call_log.dart';
import 'call_media.dart';
import 'push_service.dart';
import 'score_store.dart';
import 'session.dart';
import 'chat_store.dart';

/// Whether a call is incoming (they rang us) or outgoing (we rang them).
enum CallDirection { incoming, outgoing }

/// The lifecycle of a call. [ringing] → [connected] → [ended], or short-circuit
/// to [declined] if the callee rejects.
enum CallStatus { ringing, connected, ended, declined }

/// One live call between this device and a peer.
@immutable
class CallSession {
  final String callId;
  final AppUser peer;
  final bool video;
  final CallDirection direction;
  final CallStatus status;
  final DateTime? connectedAt;

  const CallSession({
    required this.callId,
    required this.peer,
    required this.video,
    required this.direction,
    required this.status,
    this.connectedAt,
  });

  CallSession copyWith({CallStatus? status, DateTime? connectedAt}) {
    return CallSession(
      callId: callId,
      peer: peer,
      video: video,
      direction: direction,
      status: status ?? this.status,
      connectedAt: connectedAt ?? this.connectedAt,
    );
  }
}

/// Coordinates real, synced call signaling over the relay.
///
/// This actually *rings the other device*: an outgoing call sends a `call`
/// offer to the peer's inbox, their app shows an incoming-call screen, and
/// accept / decline / hang-up are all mirrored back so both sides stay in
/// sync. (Live audio/video media would need WebRTC plus microphone/camera
/// access on real devices — the signaling and call UI here are genuine, the
/// media stream is the piece a browser demo can't carry.)
class CallService {
  CallService._();
  static final CallService instance = CallService._();

  /// The current call, or null when idle. The app root listens to this and
  /// shows the call screen whenever it is non-null.
  final ValueNotifier<CallSession?> current = ValueNotifier<CallSession?>(null);

  /// When true, the in-call UI collapses to a "return to call" banner so
  /// the user can keep using the app mid-call.
  final ValueNotifier<bool> minimized = ValueNotifier<bool>(false);

  /// The most recent in-call reaction (a floating emoji). Bumped on every
  /// reaction — even a repeat of the same emoji — so the UI animates each one.
  final ValueNotifier<CallReaction?> reaction =
      ValueNotifier<CallReaction?>(null);
  int _reactionSeq = 0;

  /// The peer's live media state (camera on / sharing screen), announced by
  /// their device over the relay so this side can show it.
  final ValueNotifier<({bool video, bool screen})> peerMedia =
      ValueNotifier((video: false, screen: false));

  int _seq = 0;

  /// How long an outgoing call rings before giving up as "no answer".
  /// Mutable so tests can shrink it.
  static Duration ringTimeout = const Duration(seconds: 45);
  Timer? _ringTimer;

  /// True when a call is already ringing or connected (used to send "busy").
  bool get isBusy {
    final c = current.value;
    return c != null &&
        (c.status == CallStatus.ringing || c.status == CallStatus.connected);
  }

  String _newCallId(String peerPhone) {
    _seq++;
    return 'call_${RelayService.digits(peerPhone)}_${DateTime.now().millisecondsSinceEpoch}_$_seq';
  }

  /// SDP offer received from a caller, awaiting our answer on accept().
  String? _pendingOfferSdp;

  /// Call ids already written to the log, so a single call is recorded once.
  final Set<String> _loggedCallIds = {};

  /// Appends [c] to the call history, inferring the log direction: outgoing
  /// stays outgoing; an incoming call that connected is "incoming", one that
  /// never connected is "missed".
  void _logCall(CallSession c) {
    if (c.callId.isEmpty || _loggedCallIds.contains(c.callId)) return;
    _loggedCallIds.add(c.callId);
    final connected = c.connectedAt != null;
    final log.CallDirection dir = c.direction == CallDirection.outgoing
        ? log.CallDirection.outgoing
        : (connected ? log.CallDirection.incoming : log.CallDirection.missed);
    final duration = c.connectedAt == null
        ? 0
        : DateTime.now().difference(c.connectedAt!).inSeconds;
    CallLog.instance.add(log.CallRecord(
      id: c.callId,
      user: c.peer,
      time: DateTime.now(),
      type: c.video ? log.CallType.video : log.CallType.voice,
      direction: dir,
      durationSeconds: duration,
    ));
  }

  /// Places an outgoing call to [peer] and rings their device.
  void startOutgoing(AppUser peer, {required bool video}) {
    if (isBusy) return;
    // Reward call activity and unlock the caller badge.
    ScoreStore.instance.award(ScoreStore.pointsPerCall);
    ScoreStore.instance.recordFlag('made_call');
    final id = _newCallId(peer.phone);
    RelayService.instance.currentCallId = id;
    minimized.value = false;
    peerMedia.value = (video: false, screen: false);
    current.value = CallSession(
      callId: id,
      peer: peer,
      video: video,
      direction: CallDirection.outgoing,
      status: CallStatus.ringing,
    );
    _beginOutgoing(peer.phone, id, video);
    // Give up automatically if they never pick up, which also offers the
    // voicemail flow instead of ringing forever.
    _ringTimer?.cancel();
    _ringTimer = Timer(ringTimeout, () {
      final c = current.value;
      if (c == null || c.callId != id) return;
      if (c.status != CallStatus.ringing) return;
      _logCall(c);
      CallMedia.instance.hangUp();
      current.value = c.copyWith(status: CallStatus.ended);
    });
  }

  /// Sets up WebRTC media (web only) then rings the peer with the SDP offer.
  Future<void> _beginOutgoing(String phone, String id, bool video) async {
    final sdp = await CallMedia.instance.createOffer(phone, video);
    RelayService.instance
        .sendCall(phone, kind: 'offer', callId: id, video: video, sdp: sdp);
    // Wake their device over APNs too, so the call rings even when the
    // app is closed (no-op until push is configured).
    final me = Session.instance.user.value;
    PushService.instance.notify(phone,
        title: me == null || me.name.isEmpty ? 'Incoming call' : me.name,
        body: video ? 'Incoming video call' : 'Incoming call');
  }

  /// Accepts the current incoming call.
  void accept() {
    _ringTimer?.cancel();
    final c = current.value;
    if (c == null || c.direction != CallDirection.incoming) return;
    RelayService.instance.currentCallId = c.callId;
    current.value = c.copyWith(
      status: CallStatus.connected,
      connectedAt: DateTime.now(),
    );
    _beginAnswer(c);
  }

  /// Sets up WebRTC media (web only) from the pending offer, then answers.
  Future<void> _beginAnswer(CallSession c) async {
    final offer = _pendingOfferSdp;
    final sdp = offer == null
        ? null
        : await CallMedia.instance.createAnswer(c.peer.phone, offer, c.video);
    RelayService.instance.sendCall(c.peer.phone,
        kind: 'answer', callId: c.callId, video: c.video, sdp: sdp);
  }

  /// Declines the current incoming call, telling the caller.
  void decline() {
    _ringTimer?.cancel();
    final c = current.value;
    if (c == null) return;
    RelayService.instance.sendCall(c.peer.phone,
        kind: 'decline', callId: c.callId, video: c.video);
    _logCall(c);
    _pendingOfferSdp = null;
    CallMedia.instance.hangUp();
    current.value = null;
    minimized.value = false;
  }

  /// Hangs up (cancels a ringing outgoing call, or ends a connected one).
  void end() {
    _ringTimer?.cancel();
    final c = current.value;
    if (c == null) return;
    RelayService.instance
        .sendCall(c.peer.phone, kind: 'end', callId: c.callId, video: c.video);
    _logCall(c);
    _pendingOfferSdp = null;
    CallMedia.instance.hangUp();
    current.value = null;
    minimized.value = false;
  }

  /// Clears a terminal (ended/declined) session once the UI has shown it.
  void clear() {
    _ringTimer?.cancel();
    current.value = null;
    minimized.value = false;
    peerMedia.value = (video: false, screen: false);
  }

  /// Leaves a voicemail for [peer] after an unanswered call: records a voice
  /// message flagged as a voicemail into the conversation and delivers it over
  /// the relay to a real peer. Returns false if [seconds] is empty.
  bool leaveVoicemail(AppUser peer, int seconds) {
    if (seconds <= 0) return false;
    final store = ChatStore.instance;
    var chat = store.chatWithContact(peer.id) ??
        store.chatWithContact(peer.phone);
    if (chat == null) {
      chat = Chat(id: 'chat_${peer.phone}', contact: peer, messages: const []);
      store.upsert(chat);
    }
    final msg = Message(
      id: 'vm_${DateTime.now().microsecondsSinceEpoch}',
      text: '',
      time: DateTime.now(),
      isMe: true,
      status: MessageStatus.sent,
      isVoice: true,
      isVoicemail: true,
      voiceSeconds: seconds,
    );
    store.addMessage(chat.id, msg);
    if (RelayConfig.isEnabled) {
      RelayService.instance.send(peer.phone, msg);
    }
    return true;
  }

  // --- Remote signaling (called by RelayService when events arrive) ---

  void onRemoteOffer(AppUser peer, String callId, bool video, {String? sdp}) {
    // A fresh offer for the call we're ALREADY on is a renegotiation (the
    // peer turned on their camera or started sharing their screen mid-call)
    // — answer it in place, never treat it as a second incoming call.
    final active = current.value;
    if (active != null &&
        active.callId == callId &&
        active.status == CallStatus.connected) {
      if (sdp != null) _answerRenegotiation(active, sdp);
      return;
    }
    if (isBusy) {
      // We're already on a call — tell them we're busy (a decline).
      RelayService.instance
          .sendCall(peer.phone, kind: 'decline', callId: callId, video: video);
      return;
    }
    // Privacy: blocked numbers never ring; and when "silence unknown callers"
    // is on, only people you've chatted with get through. Both silently
    // decline so the device stays quiet.
    if (AppState.isBlocked(peer.phone) || _shouldSilence(peer)) {
      RelayService.instance
          .sendCall(peer.phone, kind: 'decline', callId: callId, video: video);
      return;
    }
    _pendingOfferSdp = sdp;
    RelayService.instance.currentCallId = callId;
    minimized.value = false;
    peerMedia.value = (video: false, screen: false);
    current.value = CallSession(
      callId: callId,
      peer: peer,
      video: video,
      direction: CallDirection.incoming,
      status: CallStatus.ringing,
    );
  }

  /// True when "silence unknown callers" is on and [peer] isn't someone we
  /// already have a conversation with (matched by phone digits or contact id).
  bool _shouldSilence(AppUser peer) {
    if (!AppState.silenceUnknownCallers.value) return false;
    final digits = RelayService.digits(peer.phone);
    final known = ChatStore.instance.allChats.any((c) =>
        RelayService.digits(c.contact.phone) == digits ||
        c.contact.id == peer.id);
    return !known;
  }

  /// Applies the peer's answer to a mid-call renegotiation offer.
  Future<void> _answerRenegotiation(CallSession c, String offerSdp) async {
    final answer = await CallMedia.instance.answerRenegotiation(offerSdp);
    if (answer == null) return;
    RelayService.instance.sendCall(c.peer.phone,
        kind: 'answer', callId: c.callId, video: c.video, sdp: answer);
  }

  void onRemoteAnswer(String callId, {String? sdp}) {
    final c = current.value;
    if (c == null || c.callId != callId) return;
    _ringTimer?.cancel();
    if (sdp != null) CallMedia.instance.setRemoteAnswer(sdp);
    // A renegotiation answer arrives on an already-connected call — applying
    // the SDP is all it needs; don't reset the call timer.
    if (c.status == CallStatus.connected) return;
    current.value =
        c.copyWith(status: CallStatus.connected, connectedAt: DateTime.now());
  }

  /// A remote ICE candidate for the active call.
  void onRemoteIce(String callId, Map<String, dynamic> candidate) {
    final c = current.value;
    if (c == null || (callId.isNotEmpty && c.callId != callId)) return;
    CallMedia.instance.addIce(candidate);
  }

  void onRemoteDecline(String callId) {
    final c = current.value;
    if (c == null || c.callId != callId) return;
    _logCall(c);
    CallMedia.instance.hangUp();
    current.value = c.copyWith(status: CallStatus.declined);
  }

  void onRemoteEnd(String callId) {
    final c = current.value;
    if (c == null || c.callId != callId) return;
    _logCall(c);
    CallMedia.instance.hangUp();
    current.value = c.copyWith(status: CallStatus.ended);
  }

  // --- Mid-call media: camera / screen with renegotiation + announcements ---

  /// Turns the camera on/off mid-call. Captures a camera for voice-only calls
  /// (with the renegotiation round the new track needs) and tells the peer.
  Future<void> setVideo(bool on) async {
    final c = current.value;
    if (c == null) return;
    final addedTrack = await CallMedia.instance.enableCamera(on);
    if (addedTrack || CallMedia.instance.takeRenegotiateNeeded()) {
      await _renegotiate(c);
    }
    _announceMedia(c);
  }

  /// Starts/stops screen sharing, renegotiating when the share added a brand
  /// new track (voice calls), and announces the state. Returns the
  /// human-readable error, or null on success.
  Future<String?> toggleScreenShare() async {
    final c = current.value;
    if (c == null) return 'No active call.';
    final error = await CallMedia.instance.toggleScreenShare();
    if (error == null) {
      if (CallMedia.instance.takeRenegotiateNeeded()) await _renegotiate(c);
      _announceMedia(c);
    }
    return error;
  }

  /// Sends a fresh offer for the LIVE call so a newly added track (camera or
  /// screen) actually starts flowing to the peer.
  Future<void> _renegotiate(CallSession c) async {
    final sdp = await CallMedia.instance.createRenegotiationOffer();
    if (sdp == null) return;
    RelayService.instance.sendCall(c.peer.phone,
        kind: 'offer', callId: c.callId, video: c.video, sdp: sdp);
  }

  /// Announces this side's camera/screen state so the peer's UI can show it.
  void _announceMedia(CallSession c) {
    RelayService.instance.sendCall(c.peer.phone,
        kind: 'media',
        callId: c.callId,
        video: c.video,
        media: {
          'video': CallMedia.instance.localVideo.value,
          'screen': CallMedia.instance.screenSharing.value,
        });
  }

  /// The peer announced their camera/screen state.
  void onRemoteMediaState(String callId, Map<String, dynamic>? media) {
    final c = current.value;
    if (c == null || c.callId != callId || media == null) return;
    peerMedia.value =
        (video: media['video'] == true, screen: media['screen'] == true);
  }

  // --- In-call reactions (floating emoji) ---

  /// Sends an emoji reaction to the peer and shows it locally right away.
  void sendReaction(String emoji) {
    final c = current.value;
    if (c == null || emoji.isEmpty) return;
    _emitReaction(emoji, fromMe: true);
    ScoreStore.instance.recordFlag('call_reaction');
    RelayService.instance.sendCall(c.peer.phone,
        kind: 'reaction', callId: c.callId, video: c.video, emoji: emoji);
  }

  /// Handles a reaction sent by the peer during [callId].
  void onRemoteReaction(String callId, String? emoji) {
    final c = current.value;
    if (c == null || c.callId != callId || emoji == null || emoji.isEmpty) {
      return;
    }
    _emitReaction(emoji, fromMe: false);
  }

  void _emitReaction(String emoji, {required bool fromMe}) {
    reaction.value =
        CallReaction(emoji: emoji, fromMe: fromMe, seq: ++_reactionSeq);
  }

  @visibleForTesting
  void resetForTest() {
    current.value = null;
    minimized.value = false;
    reaction.value = null;
    peerMedia.value = (video: false, screen: false);
    _seq = 0;
    _reactionSeq = 0;
    _loggedCallIds.clear();
  }
}

/// A one-shot in-call reaction. [seq] increases with each reaction so the UI
/// can animate repeats of the same emoji.
class CallReaction {
  final String emoji;
  final bool fromMe;
  final int seq;
  const CallReaction(
      {required this.emoji, required this.fromMe, required this.seq});
}
