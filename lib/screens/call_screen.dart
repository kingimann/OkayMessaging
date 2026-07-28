import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../models/chat.dart';
import '../models/message.dart';
import '../relay/relay_config.dart';
import '../relay/relay_service.dart';
import '../state/call_media.dart';
import '../state/call_service.dart';
import '../state/chat_store.dart';
import '../theme/app_theme.dart';
import '../util/phone_format.dart';
import '../util/ringtone.dart';
import '../widgets/user_avatar.dart';
import 'chat_screen.dart';

/// The full-screen call UI, driven entirely by [CallService].
///
/// It handles both directions: an outgoing call shows "Ringing…" until the
/// peer answers; an incoming call shows Accept / Decline. Once connected a live
/// timer runs. Every button maps to a real relay signal, so hanging up or
/// declining is mirrored on the other device.
class CallScreen extends StatefulWidget {
  final CallSession session;

  const CallScreen({super.key, required this.session});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen>
    with SingleTickerProviderStateMixin {
  /// Drives the expanding halo behind the avatar while the call rings.
  late final AnimationController _pulse = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1600));
  Timer? _tick;
  Timer? _dismiss;
  /// Elapsed connected time, derived from the session's connect timestamp —
  /// never from a counter, which would restart at zero every time the call
  /// screen is minimized and reopened.
  int get _seconds {
    final at = widget.session.connectedAt;
    return at == null ? 0 : DateTime.now().difference(at).inSeconds;
  }
  bool _muted = false;
  bool _speaker = false;
  late bool _video = widget.session.video;

  /// Tap the remote video to hide the controls for an unobstructed view;
  /// tap again to bring them back. Only applies while video is showing.
  bool _hideControls = false;

  @override
  void initState() {
    super.initState();
    _syncForStatus();
    CallMedia.instance.remoteReady.addListener(_onRemoteReady);
    CallMedia.instance.connectionState.addListener(_onRemoteReady);
    CallMedia.instance.localVideo.addListener(_onRemoteReady);
    CallMedia.instance.screenSharing.addListener(_onRemoteReady);
    CallService.instance.peerMedia.addListener(_onRemoteReady);
  }

  void _onRemoteReady() {
    if (mounted) setState(() {});
  }

  /// Local preview: show whenever the camera is live or the screen is being
  /// shared — NOT just when the call started as a video call. A voice call
  /// where the user turns on video/screen must show it too.
  bool get _showLocalPreview =>
      CallMedia.instance.isSupported &&
      widget.session.status == CallStatus.connected &&
      (CallMedia.instance.localVideo.value ||
          CallMedia.instance.screenSharing.value);

  /// Remote video: a stream has arrived and the peer is sending video or a
  /// screen (their announcement), or the call was a video call from the start.
  bool get _showRemoteVideo {
    if (!CallMedia.instance.isSupported) return false;
    if (widget.session.status != CallStatus.connected) return false;
    if (!CallMedia.instance.remoteReady.value) return false;
    final pm = CallService.instance.peerMedia.value;
    return widget.session.video || pm.video || pm.screen;
  }

  /// True while the media path is still negotiating on a connected call.
  bool get _connecting {
    if (widget.session.status != CallStatus.connected) return false;
    if (!CallMedia.instance.isSupported) return false;
    final s = CallMedia.instance.connectionState.value;
    return s == 'new' || s == 'connecting';
  }

  @override
  void didUpdateWidget(CallScreen old) {
    super.didUpdateWidget(old);
    if (old.session.status != widget.session.status) _syncForStatus();
  }

  void _syncForStatus() {
    final s = widget.session.status;
    // Ring while waiting: a double-chirp + vibration for an incoming call,
    // a quieter ring-back for an outgoing one. Anything else stops it.
    if (s == CallStatus.ringing) {
      startRinging(
          incoming: widget.session.direction == CallDirection.incoming);
      _pulse.repeat();
    } else {
      stopRinging();
      _pulse.stop();
    }
    if (s == CallStatus.connected && _tick == null) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
      // Video calls are held at arm's length — default to speakerphone,
      // the way every calling app does. Voice stays on the earpiece.
      if (widget.session.video && !_speaker) {
        _speaker = true;
        CallMedia.instance.setSpeaker(true);
      }
    }
    if (s == CallStatus.ended || s == CallStatus.declined) {
      _tick?.cancel();
      _tick = null;
      // When we can offer a voicemail, keep the screen up so the user can
      // choose; otherwise show the terminal state briefly, then dismiss.
      if (!_offerVoicemail) {
        _dismiss ??= Timer(const Duration(milliseconds: 1400), () {
          CallService.instance.clear();
        });
      }
    }
  }

  /// After an outgoing call that never connected, the caller can leave a
  /// voicemail (delivered as a voice message; the callee's settings decide
  /// whether it's accepted).
  bool get _offerVoicemail {
    final s = widget.session;
    final terminal =
        s.status == CallStatus.ended || s.status == CallStatus.declined;
    return terminal &&
        !s.isGroup &&
        s.direction == CallDirection.outgoing &&
        s.connectedAt == null;
  }

  @override
  void dispose() {
    stopRinging();
    _pulse.dispose();
    _tick?.cancel();
    _dismiss?.cancel();
    CallMedia.instance.remoteReady.removeListener(_onRemoteReady);
    CallMedia.instance.connectionState.removeListener(_onRemoteReady);
    CallMedia.instance.localVideo.removeListener(_onRemoteReady);
    CallMedia.instance.screenSharing.removeListener(_onRemoteReady);
    CallService.instance.peerMedia.removeListener(_onRemoteReady);
    super.dispose();
  }

  String get _statusLabel {
    final s = widget.session;
    switch (s.status) {
      case CallStatus.ringing:
        if (s.direction == CallDirection.incoming) {
          if (s.isGroup) {
            final who =
                s.callerName.isEmpty ? 'A member' : s.callerName.split(' ').first;
            return s.video
                ? '$who invited you to a video call'
                : '$who invited you to a group call';
          }
          return s.video ? 'Incoming video call' : 'Incoming call';
        }
        return s.isGroup
            ? 'Ringing ${s.members.length} member${s.members.length == 1 ? '' : 's'}…'
            : (s.video ? 'Video calling…' : 'Ringing…');
      case CallStatus.connected:
        if (s.isGroup) {
          final m = _seconds ~/ 60;
          final sec = _seconds % 60;
          // You plus everyone whose "joined" has arrived.
          return '${s.joinedCount + 1} on the call · '
              '$m:${sec.toString().padLeft(2, '0')}';
        }
        if (CallMedia.instance.onHold.value) return 'On hold';
        // Reflect the live WebRTC media state so a still-negotiating or
        // dropped connection isn't shown as a running call.
        if (CallMedia.instance.isSupported) {
          switch (CallMedia.instance.connectionState.value) {
            case 'new':
            case 'connecting':
              return 'Connecting…';
            case 'disconnected':
              return 'Reconnecting…';
            case 'failed':
              return 'Connection lost';
          }
        }
        final m = _seconds ~/ 60;
        final sec = _seconds % 60;
        return '$m:${sec.toString().padLeft(2, '0')}';
      case CallStatus.declined:
        return 'Call declined';
      case CallStatus.ended:
        return 'Call ended';
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final incomingRinging = session.direction == CallDirection.incoming &&
        session.status == CallStatus.ringing;

    final remoteRenderer = CallMedia.instance.remoteRenderer;
    final localRenderer = CallMedia.instance.localRenderer;
    final showingRemoteVideo = _showRemoteVideo && remoteRenderer != null;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Remote video fills the screen once it arrives; otherwise a gradient.
          if (showingRemoteVideo)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _hideControls = !_hideControls),
              child: RTCVideoView(remoteRenderer,
                  objectFit:
                      RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
            )
          else
            DecoratedBox(
              // Tinted with the caller's own colour so each call feels
              // like *that* person, not a generic black screen.
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color.lerp(const Color(0xFF16181C),
                        _peerColor(session.peer.avatarColor), 0.35)!,
                    const Color(0xFF000000),
                  ],
                ),
              ),
            ),
          // Local camera/screen preview (top-right) whenever we're sending.
          if (_showLocalPreview && localRenderer != null)
            Positioned(
              top: 48,
              right: 16,
              width: 108,
              height: 150,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: RTCVideoView(localRenderer, mirror: true),
              ),
            ),
          // Collapse the call into a floating banner and keep using the app.
          if (session.status == CallStatus.connected)
            Positioned(
              top: MediaQuery.of(context).padding.top + 8,
              left: 8,
              child: IconButton(
                icon: const Icon(Icons.keyboard_arrow_down,
                    color: Colors.white, size: 30),
                tooltip: 'Minimize call',
                onPressed: () => CallService.instance.minimized.value = true,
              ),
            ),
          AnimatedOpacity(
            duration: const Duration(milliseconds: 200),
            opacity: _hideControls && showingRemoteVideo ? 0.0 : 1.0,
            child: IgnorePointer(
              ignoring: _hideControls && showingRemoteVideo,
              child: SafeArea(
            child: Column(
              children: [
                const SizedBox(height: 44),
                if (!showingRemoteVideo) ...[
                  _RingingHalo(
                    animation: _pulse,
                    active: session.status == CallStatus.ringing,
                    color: _peerColor(session.peer.avatarColor),
                    child: UserAvatar(user: session.peer, radius: 56),
                  ),
                  const SizedBox(height: 20),
                ],
                Text(
                  // A bare number reads like a phone would print it.
                  formatPhoneForDisplay(session.peer.name),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (_connecting)
                    const Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white70),
                      ),
                    )
                  else
                    Icon(
                      session.video ? Icons.videocam : Icons.call,
                      size: 16,
                      color: Colors.white70,
                    ),
                  if (!_connecting) const SizedBox(width: 6),
                  Text(
                    _statusLabel,
                    style: const TextStyle(color: Colors.white70, fontSize: 16),
                  ),
                ],
              ),
              if (session.isGroup)
                // Flexible + scroll so a big roster squeezes rather than
                // overflowing the column on small screens.
                Flexible(
                  child: SingleChildScrollView(
                    child: _GroupRoster(session: session),
                  ),
                ),
              // Live link quality from WebRTC packet-loss stats, so a bad
              // call is visibly the network's fault rather than a mystery.
              if (session.status == CallStatus.connected)
                ValueListenableBuilder<int>(
                  valueListenable: CallMedia.instance.quality,
                  builder: (context, bars, _) => bars == 0
                      ? const SizedBox.shrink()
                      : Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              for (var i = 1; i <= 3; i++)
                                Container(
                                  width: 4,
                                  height: 5.0 + i * 4,
                                  margin: const EdgeInsets.symmetric(
                                      horizontal: 1.5),
                                  decoration: BoxDecoration(
                                    color: i <= bars
                                        ? (bars == 1
                                            ? Colors.orangeAccent
                                            : Colors.white70)
                                        : Colors.white24,
                                    borderRadius: BorderRadius.circular(1.5),
                                  ),
                                ),
                              if (bars == 1) ...[
                                const SizedBox(width: 6),
                                const Text('Weak connection',
                                    style: TextStyle(
                                        color: Colors.orangeAccent,
                                        fontSize: 12.5)),
                              ],
                            ],
                          ),
                        ),
                ),
              // The call handshake rides the encrypted relay path — say so,
              // the way every serious calling app does.
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.lock, size: 12, color: Colors.white38),
                  const SizedBox(width: 5),
                  Text(
                    'End-to-end encrypted',
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.38),
                        fontSize: 12.5),
                  ),
                ],
              ),
              // Who is sending what: make camera/screen state visible to
              // both sides, so nobody broadcasts without knowing it.
              if (session.status == CallStatus.connected) ...[
                const SizedBox(height: 10),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    if (CallMedia.instance.screenSharing.value)
                      _mediaBadge(
                          Icons.screen_share, 'You\'re sharing your screen'),
                    if (!CallMedia.instance.screenSharing.value &&
                        !session.video &&
                        CallMedia.instance.localVideo.value)
                      _mediaBadge(Icons.videocam, 'Your camera is on'),
                    if (CallService.instance.peerMedia.value.screen)
                      _mediaBadge(
                          Icons.screen_share,
                          '${session.peer.name.split(' ').first} is sharing '
                          'their screen'),
                    if (!CallService.instance.peerMedia.value.screen &&
                        !session.video &&
                        CallService.instance.peerMedia.value.video)
                      _mediaBadge(
                          Icons.videocam,
                          '${session.peer.name.split(' ').first}\'s camera '
                          'is on'),
                  ],
                ),
              ],
              const Spacer(),
              const SizedBox(height: 24),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: incomingRinging
                    ? _incomingControls()
                    : _offerVoicemail
                        ? _voicemailControls()
                        : _activeControls(),
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
            ),
          ),
          // Floating emoji reactions drift up over everything mid-call.
          if (session.status == CallStatus.connected)
            const Positioned.fill(child: _CallReactionsOverlay()),
          ],
      ),
    );
  }

  /// Terminal controls after an unanswered outgoing call: dismiss, or record a
  /// voicemail for the person we couldn't reach.
  Widget _voicemailControls() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'No answer',
          style: TextStyle(
              color: Colors.white.withValues(alpha: 0.7), fontSize: 14),
        ),
        const SizedBox(height: 18),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _CallControl(
              icon: Icons.close,
              label: 'Close',
              onTap: () => CallService.instance.clear(),
            ),
            _CallControl(
              icon: Icons.voicemail,
              label: 'Voicemail',
              background: AppColors.tealGreenDark,
              size: 68,
              onTap: _recordVoicemail,
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _recordVoicemail() async {
    final seconds = await showModalBottomSheet<int>(
      context: context,
      isDismissible: true,
      backgroundColor: const Color(0xFF16181C),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _VoicemailRecorder(peerName: widget.session.peer.name),
    );
    if (seconds != null && seconds > 0 && mounted) {
      final sent =
          CallService.instance.leaveVoicemail(widget.session.peer, seconds);
      final messenger = ScaffoldMessenger.of(context);
      CallService.instance.clear();
      messenger.showSnackBar(SnackBar(
        content: Text(sent ? 'Voicemail sent' : 'Voicemail too short'),
      ));
    }
  }

  Widget _incomingControls() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _CallControl(
              icon: Icons.call_end,
              label: 'Decline',
              background: Colors.red,
              onTap: () => CallService.instance.decline(),
            ),
            _CallControl(
              icon: Icons.call,
              label: 'Accept',
              background: Colors.green,
              onTap: () => CallService.instance.accept(),
            ),
          ],
        ),
        const SizedBox(height: 14),
        TextButton.icon(
          onPressed: _declineWithMessage,
          icon: const Icon(Icons.chat_bubble_outline,
              color: Colors.white70, size: 18),
          label: const Text('Message',
              style: TextStyle(color: Colors.white70)),
        ),
      ],
    );
  }

  /// Declines the incoming call and sends the caller a quick reply.
  Future<void> _declineWithMessage() async {
    const replies = [
      'Can\'t talk right now',
      'Call you back later',
      'On my way',
      'What\'s up?',
    ];
    final peer = widget.session.peer;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final r in replies)
              ListTile(
                title: Text(r),
                onTap: () => Navigator.of(sheetContext).pop(r),
              ),
          ],
        ),
      ),
    );
    if (choice == null) return;
    CallService.instance.decline();
    // Deliver the quick reply into the conversation with the caller.
    final store = ChatStore.instance;
    var chat = store.chatWithContact(peer.id);
    chat ??= Chat(id: 'chat_${peer.id}', contact: peer, messages: const []);
    store.upsert(chat);
    final msg = Message(
      id: 'declmsg_${DateTime.now().microsecondsSinceEpoch}',
      text: choice,
      time: DateTime.now(),
      isMe: true,
      status: MessageStatus.sent,
    );
    store.addMessage(chat.id, msg);
    if (RelayConfig.isEnabled && peer.phone.isNotEmpty) {
      RelayService.instance.send(peer.phone, msg);
    }
  }

  /// A small translucent pill announcing a live camera/screen state.
  Widget _mediaBadge(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: Colors.greenAccent.shade100),
          const SizedBox(width: 5),
          Text(label,
              style: const TextStyle(color: Colors.white70, fontSize: 12)),
        ],
      ),
    );
  }

  /// A quick emoji picker; the chosen emoji floats up on both devices.
  void _showReactions(BuildContext context) {
    const emojis = ['👍', '❤️', '😂', '😮', '🎉', '👏', '🔥', '😢'];
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1B1D22),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
          child: Wrap(
            alignment: WrapAlignment.center,
            children: [
              for (final e in emojis)
                InkWell(
                  borderRadius: BorderRadius.circular(30),
                  onTap: () {
                    CallService.instance.sendReaction(e);
                    Navigator.pop(sheetContext);
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Text(e, style: const TextStyle(fontSize: 32)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _activeControls() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Toggle row, grouped on a translucent bar.
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(28),
          ),
          child: Wrap(
            alignment: WrapAlignment.center,
            spacing: 6,
            runSpacing: 8,
            children: [
              _CallControl(
                icon: _muted ? Icons.mic_off : Icons.mic,
                label: _muted ? 'Unmute' : 'Mute',
                active: _muted,
                onTap: () {
                  setState(() => _muted = !_muted);
                  CallMedia.instance.setMuted(_muted);
                },
              ),
              // Hold: stop sending and hearing anything without dropping
              // the connection.
              ValueListenableBuilder<bool>(
                valueListenable: CallMedia.instance.onHold,
                builder: (context, held, _) => _CallControl(
                  icon: held ? Icons.play_arrow : Icons.pause,
                  label: held ? 'Resume' : 'Hold',
                  active: held,
                  onTap: () => CallMedia.instance.setHold(!held),
                ),
              ),
              _CallControl(
                icon: _speaker ? Icons.volume_up : Icons.volume_down_outlined,
                label: 'Speaker',
                active: _speaker,
                onTap: () {
                  setState(() => _speaker = !_speaker);
                  CallMedia.instance.setSpeaker(_speaker);
                },
              ),
              _CallControl(
                icon: _video ? Icons.videocam : Icons.videocam_off,
                label: 'Video',
                active: _video,
                onTap: () {
                  setState(() => _video = !_video);
                  // Captures a camera on demand for voice calls, runs the
                  // renegotiation the new track needs, and tells the peer.
                  CallService.instance.setVideo(_video);
                },
              ),
              if (_video)
                _CallControl(
                  icon: Icons.cameraswitch,
                  label: 'Flip',
                  onTap: () => CallMedia.instance.switchCamera(),
                ),
              // Share this screen into the call (desktop/Android Chrome;
              // iPhone Safari doesn't allow web screen capture).
              ValueListenableBuilder<bool>(
                valueListenable: CallMedia.instance.screenSharing,
                builder: (context, sharing, _) => _CallControl(
                  icon: sharing
                      ? Icons.stop_screen_share
                      : Icons.screen_share_outlined,
                  label: sharing ? 'Stop share' : 'Share screen',
                  active: sharing,
                  onTap: () async {
                    final error =
                        await CallService.instance.toggleScreenShare();
                    if (error != null && context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(error)),
                      );
                    }
                  },
                ),
              ),
              // Send a floating emoji reaction to the other person.
              _CallControl(
                icon: Icons.add_reaction_outlined,
                label: 'React',
                onTap: () => _showReactions(context),
              ),
              // Text mid-call: the call collapses to the return banner and
              // the conversation opens underneath.
              _CallControl(
                icon: Icons.chat_bubble_outline,
                label: 'Message',
                onTap: () {
                  final chat = ChatStore.instance
                          .chatWithContact(widget.session.peer.id) ??
                      ChatStore.instance
                          .chatWithContact(widget.session.peer.phone);
                  if (chat == null) return;
                  CallService.instance.minimized.value = true;
                  Navigator.of(context, rootNavigator: true).push(
                    MaterialPageRoute(
                        builder: (_) => ChatScreen(chat: chat)),
                  );
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        // Prominent hang-up button.
        _CallControl(
          icon: Icons.call_end,
          label: 'End',
          background: Colors.red,
          size: 68,
          onTap: () => CallService.instance.end(),
        ),
      ],
    );
  }
}

/// The members of a group call, each with where they are in it. Lives under
/// the call status so the caller can watch the room fill up (or not).
class _GroupRoster extends StatelessWidget {
  final CallSession session;
  const _GroupRoster({required this.session});

  (String, Color) _describe(GroupCallMember m) => switch (m.state) {
        GroupCallMemberState.joined => ('On the call', Colors.greenAccent),
        GroupCallMemberState.ringing => ('Ringing…', Colors.white70),
        GroupCallMemberState.declined => ('Declined', Colors.orangeAccent),
        GroupCallMemberState.left => ('Left', Colors.white38),
      };

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 0),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 10,
        runSpacing: 10,
        children: [
          for (final m in session.members)
            Container(
              padding: const EdgeInsets.fromLTRB(6, 6, 14, 6),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(24),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Opacity(
                    opacity:
                        m.state == GroupCallMemberState.joined ? 1.0 : 0.55,
                    child: UserAvatar(user: m.user, radius: 16),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        m.user.name.split(' ').first,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600),
                      ),
                      Text(
                        _describe(m).$1,
                        style: TextStyle(
                            color: _describe(m).$2, fontSize: 11.5),
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _CallControl extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool active;
  final Color? background;
  final String? label;
  final double size;

  const _CallControl({
    required this.icon,
    required this.onTap,
    this.active = false,
    this.background,
    this.label,
    this.size = 58,
  });

  @override
  Widget build(BuildContext context) {
    final bg = background ??
        (active ? Colors.white : Colors.white.withValues(alpha: 0.18));
    final fg = background != null
        ? Colors.white
        : (active ? Colors.black : Colors.white);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: bg,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: size,
              height: size,
              child: Icon(icon, color: fg, size: size * 0.44),
            ),
          ),
        ),
        if (label != null) ...[
          const SizedBox(height: 7),
          Text(label!,
              style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
        ],
      ],
    );
  }
}

/// A simple voicemail recorder sheet: a live timer with a pulsing dot and a
/// stop button that returns the recorded length in seconds.
class _VoicemailRecorder extends StatefulWidget {
  final String peerName;
  const _VoicemailRecorder({required this.peerName});

  @override
  State<_VoicemailRecorder> createState() => _VoicemailRecorderState();
}

class _VoicemailRecorderState extends State<_VoicemailRecorder>
    with SingleTickerProviderStateMixin {
  Timer? _tick;
  int _seconds = 0;
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _seconds++);
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  String get _label {
    final m = _seconds ~/ 60;
    final s = _seconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Voicemail for ${widget.peerName}',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                FadeTransition(
                  opacity: _pulse,
                  child: const Icon(Icons.fiber_manual_record,
                      color: Colors.red, size: 16),
                ),
                const SizedBox(width: 10),
                Text(_label,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 30,
                        fontWeight: FontWeight.w300,
                        fontFeatures: [FontFeature.tabularFigures()])),
              ],
            ),
            const SizedBox(height: 8),
            const Text('Recording…',
                style: TextStyle(color: Colors.white54, fontSize: 13)),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white70,
                      side: const BorderSide(color: Colors.white24),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: () => Navigator.of(context).pop(0),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.accentOn(context),
                      foregroundColor: AppColors.onAccent(context),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    icon: const Icon(Icons.send),
                    label: const Text('Send'),
                    onPressed: () => Navigator.of(context).pop(_seconds),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The floating "return to call" pill shown while the call UI is minimized:
/// the call continues, the user browses the app, and one tap brings the
/// full-screen call back.
class ReturnToCallBanner extends StatefulWidget {
  final CallSession session;
  const ReturnToCallBanner({super.key, required this.session});

  @override
  State<ReturnToCallBanner> createState() => _ReturnToCallBannerState();
}

class _ReturnToCallBannerState extends State<ReturnToCallBanner> {
  Timer? _tick;
  bool _muted = false;

  @override
  void initState() {
    super.initState();
    // Keep the elapsed-time label live.
    _tick = Timer.periodic(
        const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  String get _elapsed {
    final at = widget.session.connectedAt;
    if (at == null) return 'Ringing…';
    final d = DateTime.now().difference(at);
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 6,
      left: 12,
      right: 12,
      child: Material(
        color: const Color(0xFF1DB954),
        borderRadius: BorderRadius.circular(26),
        elevation: 8,
        child: InkWell(
          borderRadius: BorderRadius.circular(26),
          onTap: () => CallService.instance.minimized.value = false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 6, 8),
            child: Row(
              children: [
                Icon(widget.session.video ? Icons.videocam : Icons.call,
                    color: Colors.white, size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${widget.session.peer.name} · $_elapsed — tap to return',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600),
                  ),
                ),
                // Mute without reopening the call — the reason you
                // minimized it in the first place.
                IconButton(
                  icon: Icon(_muted ? Icons.mic_off : Icons.mic,
                      color: Colors.white),
                  tooltip: _muted ? 'Unmute' : 'Mute',
                  onPressed: () {
                    setState(() => _muted = !_muted);
                    CallMedia.instance.setMuted(_muted);
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.call_end, color: Colors.white),
                  tooltip: 'Hang up',
                  onPressed: () => CallService.instance.end(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Full-screen overlay that spawns a floating emoji whenever a reaction
/// arrives (yours or the peer's) and animates it drifting up and fading.
class _CallReactionsOverlay extends StatefulWidget {
  const _CallReactionsOverlay();

  @override
  State<_CallReactionsOverlay> createState() => _CallReactionsOverlayState();
}

class _CallReactionsOverlayState extends State<_CallReactionsOverlay> {
  final List<CallReaction> _items = [];
  int _lastSeq = 0;

  @override
  void initState() {
    super.initState();
    CallService.instance.reaction.addListener(_onReaction);
  }

  @override
  void dispose() {
    CallService.instance.reaction.removeListener(_onReaction);
    super.dispose();
  }

  void _onReaction() {
    final r = CallService.instance.reaction.value;
    if (r == null || r.seq == _lastSeq) return;
    _lastSeq = r.seq;
    setState(() => _items.add(r));
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          for (final r in _items)
            _FloatingReaction(
              key: ValueKey(r.seq),
              reaction: r,
              onDone: () => setState(() => _items.remove(r)),
            ),
        ],
      ),
    );
  }
}

class _FloatingReaction extends StatefulWidget {
  final CallReaction reaction;
  final VoidCallback onDone;
  const _FloatingReaction(
      {super.key, required this.reaction, required this.onDone});

  @override
  State<_FloatingReaction> createState() => _FloatingReactionState();
}

class _FloatingReactionState extends State<_FloatingReaction>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2000),
  );

  @override
  void initState() {
    super.initState();
    _c.forward();
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed) widget.onDone();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Mine drift up the right side, the peer's up the left; a little sideways
    // offset by sequence keeps repeats from perfectly overlapping.
    final baseX = widget.reaction.fromMe ? 0.5 : -0.5;
    final jitter = ((widget.reaction.seq % 3) - 1) * 0.12;
    final x = (baseX + jitter).clamp(-0.9, 0.9);
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = _c.value;
        final y = 0.7 - t * 1.3; // rise from lower-middle toward the top
        final opacity = t < 0.15
            ? t / 0.15
            : (t > 0.75 ? (1 - (t - 0.75) / 0.25) : 1.0);
        final scale = 0.6 + (t < 0.2 ? t / 0.2 : 1.0) * 0.6;
        return Align(
          alignment: Alignment(x.toDouble(), y),
          child: Opacity(
            opacity: opacity.clamp(0.0, 1.0),
            child: Transform.scale(
              scale: scale,
              child: Text(widget.reaction.emoji,
                  style: const TextStyle(fontSize: 56)),
            ),
          ),
        );
      },
    );
  }
}

/// The caller's avatar colour, for tinting the call backdrop.
Color _peerColor(String avatarColor) {
  var hex = avatarColor.replaceFirst('#', '');
  if (hex.length == 6) hex = 'FF$hex';
  return Color(int.tryParse(hex, radix: 16) ?? 0xFF9E9E9E);
}

/// Two soft rings that swell out behind the avatar while a call rings —
/// the universal "this is live" cue.
class _RingingHalo extends StatelessWidget {
  final Animation<double> animation;
  final bool active;
  final Color color;
  final Widget child;

  const _RingingHalo({
    required this.animation,
    required this.active,
    required this.color,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    if (!active) return child;
    // The rings paint OUTSIDE the avatar's box (Clip.none + negative
    // insets) so ringing doesn't change the column's layout at all.
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        Widget ring(double phase) {
          final t = (animation.value + phase) % 1.0;
          final spread = t * 36;
          return Positioned(
            left: -spread,
            top: -spread,
            right: -spread,
            bottom: -spread,
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Color.lerp(color, Colors.white, 0.4)!
                        .withValues(alpha: (1 - t) * 0.45),
                    width: 2,
                  ),
                ),
              ),
            ),
          );
        }

        return Stack(
          clipBehavior: Clip.none,
          children: [child, ring(0), ring(0.5)],
        );
      },
    );
  }
}
