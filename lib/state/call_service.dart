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
import 'room_media.dart';
import 'score_store.dart';
import 'session.dart';
import 'chat_store.dart';

/// Whether a call is incoming (they rang us) or outgoing (we rang them).
enum CallDirection { incoming, outgoing }

/// The lifecycle of a call. [ringing] → [connected] → [ended], or short-circuit
/// to [declined] if the callee rejects.
enum CallStatus { ringing, connected, ended, declined }

/// Where one member of a group call currently is: still being rung, on the
/// call, rejected it without ever joining, or joined and then hung up.
enum GroupCallMemberState { ringing, joined, declined, left }

/// One member of a group call, with where they are in it.
@immutable
class GroupCallMember {
  final AppUser user;
  final GroupCallMemberState state;

  const GroupCallMember(this.user,
      [this.state = GroupCallMemberState.ringing]);

  GroupCallMember withState(GroupCallMemberState next) =>
      GroupCallMember(user, next);
}

/// One live call between this device and a peer.
@immutable
class CallSession {
  final String callId;

  /// Who the call is *with*: the other person for a one-to-one call, the
  /// group itself for a group call (its name and colour carry the screen).
  final AppUser peer;
  final bool video;
  final CallDirection direction;
  final CallStatus status;
  final DateTime? connectedAt;

  /// Group-call roster (everyone but this device), empty for 1:1 calls.
  final List<GroupCallMember> members;

  /// Who started a group call — shown on the incoming screen so "Trip
  /// planning" also says which member is ringing you. Empty for 1:1.
  final String callerName;

  const CallSession({
    required this.callId,
    required this.peer,
    required this.video,
    required this.direction,
    required this.status,
    this.connectedAt,
    this.members = const [],
    this.callerName = '',
  });

  /// True for a call that rings a whole group rather than one person.
  bool get isGroup => members.isNotEmpty;

  /// Members currently on the call.
  int get joinedCount => members
      .where((m) => m.state == GroupCallMemberState.joined)
      .length;

  CallSession copyWith({
    CallStatus? status,
    DateTime? connectedAt,
    List<GroupCallMember>? members,
  }) {
    return CallSession(
      callId: callId,
      peer: peer,
      video: video,
      direction: direction,
      status: status ?? this.status,
      connectedAt: connectedAt ?? this.connectedAt,
      members: members ?? this.members,
      callerName: callerName,
    );
  }

  /// Returns a copy with [phone]'s member moved to [next]. Someone who leaves
  /// while still being rung never answered — that's a decline, not a leave.
  CallSession withMemberState(String phone, GroupCallMemberState next) {
    final digits = RelayService.digits(phone);
    return copyWith(members: [
      for (final m in members)
        if (RelayService.digits(m.user.phone) == digits)
          m.withState(next == GroupCallMemberState.left &&
                  m.state == GroupCallMemberState.ringing
              ? GroupCallMemberState.declined
              : next)
        else
          m
    ]);
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
      // The link's last reading, so "that call was choppy" leaves
      // something checkable in the log instead of only a memory.
      quality: connected ? CallMedia.instance.quality.value : 0,
    ));
    _recordInChat(c, connected: connected, duration: duration);
  }

  /// Drops a call record into the conversation itself — a missed call badge
  /// in the thread, a "Voice call · 4:32" entry for one that connected — so
  /// the chat tells the whole story, not just the Calls tab. Local only:
  /// each device writes its own record from its own signaling.
  void _recordInChat(CallSession c,
      {required bool connected, required int duration}) {
    final store = ChatStore.instance;
    var chat = store.chatWithContact(c.peer.id) ??
        store.chatWithContact(c.peer.phone) ??
        store.chatById(c.peer.id);
    if (chat == null) {
      if (RelayService.digits(c.peer.phone).isEmpty) return;
      chat = Chat(
          id: 'chat_${c.peer.phone}', contact: c.peer, messages: const []);
      store.upsert(chat);
    }
    final outgoing = c.direction == CallDirection.outgoing;
    final event = connected
        ? 'ended'
        : (outgoing
            ? (c.status == CallStatus.declined ? 'declined' : 'noanswer')
            : 'missed');
    store.addMessage(
      chat.id,
      Message(
        id: 'callmsg_${c.callId}',
        text: '',
        time: DateTime.now(),
        isMe: outgoing,
        // A call record needs no ticks; an unanswered incoming call should
        // still bump the unread badge, which addMessage does for !isMe.
        status: MessageStatus.read,
        callEvent: event,
        callVideo: c.video,
        callSeconds: duration,
      ),
    );
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
    peerOnHold.value = false;
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
      _notifyMissed(c);
      _logCall(c);
      CallMedia.instance.hangUp();
      current.value = c.copyWith(status: CallStatus.ended);
    });
  }

  /// Tells the peer a ringing call was given up on: a push so their phone
  /// says so now, and a queued 'callmiss' event so their call log and chat
  /// show the missed call whenever the app next syncs. The live offer only
  /// reaches an app that is open; without these, a call to a closed app
  /// never existed on the callee's side at all.
  void _notifyMissed(CallSession c) {
    if (c.isGroup || c.direction != CallDirection.outgoing) return;
    final me = Session.instance.user.value;
    PushService.instance.notify(c.peer.phone,
        title: me == null || me.name.isEmpty ? 'Missed call' : me.name,
        body: c.video ? 'Missed video call' : 'Missed call');
    RelayService.instance
        .sendMissedCall(c.peer.phone, callId: c.callId, video: c.video);
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
        body: video ? 'Incoming video call' : 'Incoming call',
        kind: 'call',
        callId: id,
        video: video);
  }

  /// Rings every member of [group] at once. There is no room on a server:
  /// each member's device gets its own encrypted invitation, and joins and
  /// leaves are fanned out the same way so every roster converges.
  ///
  /// Signaling and the shared call state are real; like 1:1 calls, live media
  /// is the WebRTC piece and stays pairwise, so group legs carry no SDP.
  void startGroupCall(Chat group, {required bool video}) {
    if (isBusy) return;
    final me = Session.instance.user.value;
    final myDigits = RelayService.digits(me?.phone ?? '');
    // Only members that can actually be rung belong on the roster.
    final callable = [
      for (final m in group.members)
        if (RelayService.digits(m.phone).isNotEmpty &&
            RelayService.digits(m.phone) != myDigits)
          m
    ];
    if (callable.isEmpty) return;

    ScoreStore.instance.award(ScoreStore.pointsPerCall);
    ScoreStore.instance.recordFlag('made_call');
    final id = _newCallId(group.id);
    RelayService.instance.currentCallId = id;
    minimized.value = false;
    peerMedia.value = (video: false, screen: false);
    peerOnHold.value = false;
    current.value = CallSession(
      callId: id,
      peer: group.contact,
      video: video,
      direction: CallDirection.outgoing,
      status: CallStatus.ringing,
      members: [for (final m in callable) GroupCallMember(m)],
    );
    final caller = me?.name ?? '';
    for (final member in callable) {
      RelayService.instance.sendCall(member.phone,
          kind: 'offer',
          callId: id,
          video: video,
          group: RelayService.groupCallInfo(group));
      PushService.instance.notify(member.phone,
          title: caller.isEmpty ? 'Incoming group call' : caller,
          body: 'Group call · ${group.contact.name}',
          kind: 'call',
          callId: id,
          video: video);
    }
    _ringTimer?.cancel();
    _ringTimer = Timer(ringTimeout, () {
      final c = current.value;
      if (c == null || c.callId != id || c.status != CallStatus.ringing) {
        return;
      }
      // Nobody picked up. Tell the members so their phones stop ringing.
      for (final m in c.members) {
        RelayService.instance
            .sendCall(m.user.phone, kind: 'left', callId: id, video: video);
      }
      _logCall(c);
      current.value = c.copyWith(status: CallStatus.ended);
    });
  }

  /// Accepts the current incoming call.
  void accept() {
    _ringTimer?.cancel();
    final c = current.value;
    if (c == null || c.direction != CallDirection.incoming) return;
    // Answering can arrive twice — once from the in-app UI and once echoed
    // back through CallKit's CXAnswerCallAction — and answering an already
    // connected call would tear down and redo the WebRTC handshake.
    if (c.status != CallStatus.ringing) return;
    RelayService.instance.currentCallId = c.callId;
    current.value = c.copyWith(
      status: CallStatus.connected,
      connectedAt: DateTime.now(),
    );
    if (c.isGroup) {
      // Everyone (the caller included) hears about the join the same way,
      // so every device's roster agrees without a server keeping one.
      for (final m in c.members) {
        RelayService.instance.sendCall(m.user.phone,
            kind: 'joined', callId: c.callId, video: c.video);
      }
      unawaited(_startGroupMedia(current.value ?? c));
      return;
    }
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
    if (c.isGroup) {
      for (final m in c.members) {
        RelayService.instance
            .sendCall(m.user.phone, kind: 'left', callId: c.callId, video: c.video);
      }
    } else {
      RelayService.instance.sendCall(c.peer.phone,
          kind: 'decline', callId: c.callId, video: c.video);
    }
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
    if (c.isGroup) {
      for (final m in c.members) {
        RelayService.instance
            .sendCall(m.user.phone, kind: 'left', callId: c.callId, video: c.video);
      }
    } else {
      RelayService.instance
          .sendCall(c.peer.phone, kind: 'end', callId: c.callId, video: c.video);
      // Hanging up while it was still ringing is a missed call on their side.
      if (c.status == CallStatus.ringing &&
          c.direction == CallDirection.outgoing) {
        _notifyMissed(c);
      }
    }
    _logCall(c);
    _pendingOfferSdp = null;
    CallMedia.instance.hangUp();
    if (c.isGroup) unawaited(RoomMedia.instance.leaveCall(c.callId));
    current.value = null;
    minimized.value = false;
  }

  /// Clears a terminal (ended/declined) session once the UI has shown it.
  void clear() {
    _ringTimer?.cancel();
    current.value = null;
    minimized.value = false;
    peerMedia.value = (video: false, screen: false);
    peerOnHold.value = false;
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
    // The SAME offer again while this call is already ringing (broadcast
    // and the mailbox both deliver it, and a VoIP wake fetches the queued
    // copy right after the live one): a duplicate is a no-op. It used to
    // fall through to the busy check, which declined the call with itself.
    if (active != null && active.callId == callId) return;
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
    peerOnHold.value = false;
    current.value = CallSession(
      callId: callId,
      peer: peer,
      video: video,
      direction: CallDirection.incoming,
      status: CallStatus.ringing,
    );
    // A VoIP wake answers (or declines) on the LOCK SCREEN before the app
    // has the offer — CallKit rang from the push alone. The intent was
    // parked; the offer arriving is what completes it.
    if (_pendingVoipAnswer == callId) {
      _pendingVoipAnswer = null;
      accept();
    } else if (_pendingVoipDecline == callId) {
      _pendingVoipDecline = null;
      decline();
    }
  }

  /// Lock-screen intent noted before the offer arrived (VoIP wake): CallKit
  /// answered a call the app has not received yet.
  String? _pendingVoipAnswer;
  String? _pendingVoipDecline;
  void noteVoipAnswer(String callId) {
    _pendingVoipAnswer = callId;
    _pendingVoipDecline = null;
  }

  void noteVoipDecline(String callId) {
    _pendingVoipDecline = callId;
    if (_pendingVoipAnswer == callId) _pendingVoipAnswer = null;
  }

  /// The mesh roster for a group call: everyone known to be ON it. The
  /// mesh's own pair rules (smaller digits dials, glare-free renegotiation)
  /// do the rest.
  static Set<String> joinedDigits(CallSession c) => {
        for (final m in c.members)
          if (m.state == GroupCallMemberState.joined)
            RelayService.digits(m.user.phone)
      }..remove('');

  /// Opens this device's leg of the group-call mesh: mic on, connections
  /// to whoever already joined, camera too when the call is video. Group
  /// calls carried NO media at all before the mesh existed — signaling and
  /// roster were real, sound was not.
  Future<void> _startGroupMedia(CallSession c) async {
    final problem = await RoomMedia.instance
        .joinCall(c.callId, joinedDigits(c), speaker: c.video);
    if (problem == null && c.video) {
      await RoomMedia.instance.enableCamera(true);
    }
  }

  /// A group call invitation arrived: [caller] is ringing us into
  /// [group], whose [members] came sealed inside the offer.
  void onRemoteGroupOffer(
    AppUser caller,
    String callId,
    bool video, {
    required AppUser group,
    required List<AppUser> members,
  }) {
    final active = current.value;
    // A duplicate offer for the call we're already showing changes nothing.
    if (active != null && active.callId == callId) return;
    if (isBusy) {
      // Already on a call: bow out so their roster shows us as declined.
      for (final m in members) {
        RelayService.instance
            .sendCall(m.phone, kind: 'left', callId: callId, video: video);
      }
      return;
    }
    if (AppState.isBlocked(caller.phone) || _shouldSilence(caller)) {
      RelayService.instance
          .sendCall(caller.phone, kind: 'left', callId: callId, video: video);
      return;
    }
    final myDigits =
        RelayService.digits(Session.instance.user.value?.phone ?? '');
    RelayService.instance.currentCallId = callId;
    minimized.value = false;
    peerMedia.value = (video: false, screen: false);
    peerOnHold.value = false;
    final callerDigits = RelayService.digits(caller.phone);
    current.value = CallSession(
      callId: callId,
      peer: group,
      video: video,
      direction: CallDirection.incoming,
      status: CallStatus.ringing,
      callerName: caller.name,
      members: [
        for (final m in members)
          if (RelayService.digits(m.phone).isNotEmpty &&
              RelayService.digits(m.phone) != myDigits)
            GroupCallMember(
                m,
                // Whoever is ringing us is on the call already.
                RelayService.digits(m.phone) == callerDigits
                    ? GroupCallMemberState.joined
                    : GroupCallMemberState.ringing)
      ],
    );
  }

  /// A member of the current group call joined it.
  void onRemoteJoined(String fromPhone, String callId) {
    final c = current.value;
    if (c == null || c.callId != callId || !c.isGroup) return;
    var next = c.withMemberState(fromPhone, GroupCallMemberState.joined);
    // The first join answers an outgoing group call — and opens the
    // caller's own leg of the mesh, which was pointless while the roster
    // was only ringing.
    if (next.status == CallStatus.ringing &&
        c.direction == CallDirection.outgoing) {
      _ringTimer?.cancel();
      next = next.copyWith(
          status: CallStatus.connected, connectedAt: DateTime.now());
      unawaited(_startGroupMedia(next));
    }
    current.value = next;
    RoomMedia.instance.updateCallPeers(callId, joinedDigits(next));
  }

  /// A member of the current group call left it (or declined the invite).
  void onRemoteLeft(String fromPhone, String callId) {
    final c = current.value;
    if (c == null || c.callId != callId || !c.isGroup) return;
    final fromDigits = RelayService.digits(fromPhone);
    // The caller hanging up while we're still being rung cancels the invite.
    final callerLeft = c.direction == CallDirection.incoming &&
        c.status == CallStatus.ringing &&
        c.members.any((m) =>
            RelayService.digits(m.user.phone) == fromDigits &&
            m.state == GroupCallMemberState.joined);
    var next = c.withMemberState(fromPhone, GroupCallMemberState.left);
    final everyoneGone = next.members
        .every((m) => m.state != GroupCallMemberState.joined &&
            m.state != GroupCallMemberState.ringing);
    if (callerLeft || (next.status == CallStatus.connected && everyoneGone)) {
      _logCall(next);
      next = next.copyWith(status: CallStatus.ended);
      unawaited(RoomMedia.instance.leaveCall(callId));
    } else {
      RoomMedia.instance.updateCallPeers(callId, joinedDigits(next));
    }
    current.value = next;
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
        kind: 'answer', callId: c.callId, video: c.video, sdp: answer,
        queue: false);
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
    // Log the *declined* state, so the chat record says "declined" rather
    // than reading as an ordinary unanswered call.
    final declined = c.copyWith(status: CallStatus.declined);
    _logCall(declined);
    CallMedia.instance.hangUp();
    current.value = declined;
  }

  void onRemoteEnd(String callId) {
    final c = current.value;
    if (c == null || c.callId != callId) return;
    _logCall(c);
    CallMedia.instance.hangUp();
    current.value = c.copyWith(status: CallStatus.ended);
  }

  /// A 'callmiss' notice from the caller: they gave up ringing while this
  /// app wasn't there to see the live offer (closed, dead socket). Files the
  /// missed call in the log and the chat, exactly as the live flow would
  /// have — this is what makes a call to a closed app exist at all on the
  /// callee's side, since offers are live-only and never queued.
  void onRemoteMissed(AppUser peer, String callId, bool video) {
    if (callId.isEmpty) return;
    // The live flow may have filed this one already (app open, offer rang,
    // caller's 'end' arrived): one entry per call, whichever ran first. The
    // log is checked too because a mailboxed notice can arrive days later,
    // long after the in-memory set restarted.
    if (_loggedCallIds.contains(callId) ||
        CallLog.instance.records.any((r) => r.id == callId)) {
      return;
    }
    _loggedCallIds.add(callId);
    CallLog.instance.add(log.CallRecord(
      id: callId,
      user: peer,
      time: DateTime.now(),
      type: video ? log.CallType.video : log.CallType.voice,
      direction: log.CallDirection.missed,
      durationSeconds: 0,
    ));
    final store = ChatStore.instance;
    var chat = store.chatWithContact(peer.id) ??
        store.chatWithContact(peer.phone);
    if (chat == null) {
      if (RelayService.digits(peer.phone).isEmpty) return;
      chat = Chat(
          id: 'chat_${peer.phone}', contact: peer, messages: const []);
      store.upsert(chat);
    }
    store.addMessage(
      chat.id,
      Message(
        id: 'callmsg_$callId',
        text: '',
        time: DateTime.now(),
        isMe: false,
        status: MessageStatus.read,
        callEvent: 'missed',
        callVideo: video,
        callSeconds: 0,
      ),
    );
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

  /// The zombie-call watchdog. When the far side hangs up, their 'end'
  /// event usually arrives live — but a dropped socket loses it, and this
  /// side then sat in "Reconnecting…" forever while their phone was long
  /// back in a pocket. Two answers, both driven by the media link dying:
  /// fetch the mailbox NOW (the 'end' was queued there and would otherwise
  /// wait for the next app-open), and if the link stays dead through the
  /// restart attempts, end the call locally — twenty seconds of dead air
  /// after a restart is a peer that is gone, not a peer that is slow.
  Timer? _deadLinkTimer;
  void onMediaState(String state) {
    final c = current.value;
    if (c == null || c.isGroup || c.status != CallStatus.connected) {
      _deadLinkTimer?.cancel();
      _deadLinkTimer = null;
      return;
    }
    final dead =
        state == 'disconnected' || state == 'failed' || state == 'closed';
    if (!dead) {
      _deadLinkTimer?.cancel();
      _deadLinkTimer = null;
      return;
    }
    // Their hang-up may be sitting in the mailbox this very second.
    unawaited(RelayService.instance.fetchMailbox());
    _deadLinkTimer ??= Timer(const Duration(seconds: 20), () {
      _deadLinkTimer = null;
      final cur = current.value;
      if (cur == null || cur.isGroup || cur.status != CallStatus.connected) {
        return;
      }
      final ms = CallMedia.instance.connectionState.value;
      if (ms == 'disconnected' || ms == 'failed' || ms == 'closed') {
        end();
      }
    });
  }

  /// Redials the transport under a live call after a network switch: an
  /// ICE-restart offer over the same renegotiation path a camera-on offer
  /// rides. Exactly one side restarts — the original CALLER — so a failure
  /// both ends notice at once does not produce colliding offers. Wired to
  /// [CallMedia.onNeedsIceRestart] at startup.
  Future<void> restartIce() async {
    final c = current.value;
    if (c == null || c.status != CallStatus.connected || c.isGroup) return;
    if (c.direction != CallDirection.outgoing) return;
    final sdp = await CallMedia.instance.createIceRestartOffer();
    if (sdp == null) return;
    RelayService.instance.sendCall(c.peer.phone,
        kind: 'offer', callId: c.callId, video: c.video, sdp: sdp,
        queue: false);
  }

  /// Sends a fresh offer for the LIVE call so a newly added track (camera or
  /// screen) actually starts flowing to the peer.
  Future<void> _renegotiate(CallSession c) async {
    final sdp = await CallMedia.instance.createRenegotiationOffer();
    if (sdp == null) return;
    RelayService.instance.sendCall(c.peer.phone,
        kind: 'offer', callId: c.callId, video: c.video, sdp: sdp,
        queue: false);
  }

  /// Whether the PEER put the call on hold — their silence is deliberate,
  /// and a silence with no label reads as a broken call.
  final ValueNotifier<bool> peerOnHold = ValueNotifier<bool>(false);

  /// Holds/resumes and TELLS the other side. A hold that only acted
  /// locally left the peer talking into an unexplained void.
  void setHold(bool held) {
    final c = current.value;
    CallMedia.instance.setHold(held);
    if (c != null && !c.isGroup) _announceMedia(c);
  }

  /// Announces this side's camera/screen/hold state so the peer's UI can
  /// show it.
  void _announceMedia(CallSession c) {
    RelayService.instance.sendCall(c.peer.phone,
        kind: 'media',
        callId: c.callId,
        video: c.video,
        media: {
          'video': CallMedia.instance.localVideo.value,
          'screen': CallMedia.instance.screenSharing.value,
          'hold': CallMedia.instance.onHold.value,
        });
  }

  /// The peer announced their camera/screen/hold state.
  void onRemoteMediaState(String callId, Map<String, dynamic>? media) {
    final c = current.value;
    if (c == null || c.callId != callId || media == null) return;
    peerMedia.value =
        (video: media['video'] == true, screen: media['screen'] == true);
    peerOnHold.value = media['hold'] == true;
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
    peerOnHold.value = false;
    _seq = 0;
    _reactionSeq = 0;
    _loggedCallIds.clear();
    _pendingVoipAnswer = null;
    _pendingVoipDecline = null;
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
