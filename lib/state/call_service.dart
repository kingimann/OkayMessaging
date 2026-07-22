import 'package:flutter/foundation.dart';

import '../models/user.dart';
import '../relay/relay_service.dart';

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

  /// Places an outgoing call to [peer] and rings their device.
  void startOutgoing(AppUser peer, {required bool video}) {
    if (isBusy) return;
    final id = _newCallId(peer.phone);
    current.value = CallSession(
      callId: id,
      peer: peer,
      video: video,
      direction: CallDirection.outgoing,
      status: CallStatus.ringing,
    );
    RelayService.instance
        .sendCall(peer.phone, kind: 'offer', callId: id, video: video);
  }

  /// Accepts the current incoming call.
  void accept() {
    final c = current.value;
    if (c == null || c.direction != CallDirection.incoming) return;
    current.value = c.copyWith(
      status: CallStatus.connected,
      connectedAt: DateTime.now(),
    );
    RelayService.instance
        .sendCall(c.peer.phone, kind: 'answer', callId: c.callId, video: c.video);
  }

  /// Declines the current incoming call, telling the caller.
  void decline() {
    final c = current.value;
    if (c == null) return;
    RelayService.instance.sendCall(c.peer.phone,
        kind: 'decline', callId: c.callId, video: c.video);
    current.value = null;
  }

  /// Hangs up (cancels a ringing outgoing call, or ends a connected one).
  void end() {
    final c = current.value;
    if (c == null) return;
    RelayService.instance
        .sendCall(c.peer.phone, kind: 'end', callId: c.callId, video: c.video);
    current.value = null;
  }

  /// Clears a terminal (ended/declined) session once the UI has shown it.
  void clear() {
    current.value = null;
  }

  // --- Remote signaling (called by RelayService when events arrive) ---

  void onRemoteOffer(AppUser peer, String callId, bool video) {
    if (isBusy) {
      // We're already on a call — tell them we're busy (a decline).
      RelayService.instance
          .sendCall(peer.phone, kind: 'decline', callId: callId, video: video);
      return;
    }
    current.value = CallSession(
      callId: callId,
      peer: peer,
      video: video,
      direction: CallDirection.incoming,
      status: CallStatus.ringing,
    );
  }

  void onRemoteAnswer(String callId) {
    final c = current.value;
    if (c == null || c.callId != callId) return;
    current.value =
        c.copyWith(status: CallStatus.connected, connectedAt: DateTime.now());
  }

  void onRemoteDecline(String callId) {
    final c = current.value;
    if (c == null || c.callId != callId) return;
    current.value = c.copyWith(status: CallStatus.declined);
  }

  void onRemoteEnd(String callId) {
    final c = current.value;
    if (c == null || c.callId != callId) return;
    current.value = c.copyWith(status: CallStatus.ended);
  }

  @visibleForTesting
  void resetForTest() {
    current.value = null;
    _seq = 0;
  }
}
