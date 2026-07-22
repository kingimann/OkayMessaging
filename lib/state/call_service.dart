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
import 'score_store.dart';
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

  int _seq = 0;

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
    CallLog.instance.add(log.CallRecord(
      id: c.callId,
      user: c.peer,
      time: DateTime.now(),
      type: c.video ? log.CallType.video : log.CallType.voice,
      direction: dir,
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
    current.value = CallSession(
      callId: id,
      peer: peer,
      video: video,
      direction: CallDirection.outgoing,
      status: CallStatus.ringing,
    );
    _beginOutgoing(peer.phone, id, video);
  }

  /// Sets up WebRTC media (web only) then rings the peer with the SDP offer.
  Future<void> _beginOutgoing(String phone, String id, bool video) async {
    final sdp = await CallMedia.instance.createOffer(phone, video);
    RelayService.instance
        .sendCall(phone, kind: 'offer', callId: id, video: video, sdp: sdp);
  }

  /// Accepts the current incoming call.
  void accept() {
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
    final c = current.value;
    if (c == null) return;
    RelayService.instance.sendCall(c.peer.phone,
        kind: 'decline', callId: c.callId, video: c.video);
    _logCall(c);
    _pendingOfferSdp = null;
    CallMedia.instance.hangUp();
    current.value = null;
  }

  /// Hangs up (cancels a ringing outgoing call, or ends a connected one).
  void end() {
    final c = current.value;
    if (c == null) return;
    RelayService.instance
        .sendCall(c.peer.phone, kind: 'end', callId: c.callId, video: c.video);
    _logCall(c);
    _pendingOfferSdp = null;
    CallMedia.instance.hangUp();
    current.value = null;
  }

  /// Clears a terminal (ended/declined) session once the UI has shown it.
  void clear() {
    current.value = null;
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

  void onRemoteAnswer(String callId, {String? sdp}) {
    final c = current.value;
    if (c == null || c.callId != callId) return;
    if (sdp != null) CallMedia.instance.setRemoteAnswer(sdp);
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

  @visibleForTesting
  void resetForTest() {
    current.value = null;
    _seq = 0;
    _loggedCallIds.clear();
  }
}
