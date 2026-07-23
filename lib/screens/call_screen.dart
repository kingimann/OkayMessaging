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
import '../widgets/user_avatar.dart';

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

class _CallScreenState extends State<CallScreen> {
  Timer? _tick;
  Timer? _dismiss;
  int _seconds = 0;
  bool _muted = false;
  bool _speaker = false;
  late bool _video = widget.session.video;

  @override
  void initState() {
    super.initState();
    _syncForStatus();
    CallMedia.instance.remoteReady.addListener(_onRemoteReady);
    CallMedia.instance.connectionState.addListener(_onRemoteReady);
  }

  void _onRemoteReady() {
    if (mounted) setState(() {});
  }

  bool get _showVideo =>
      CallMedia.instance.isSupported &&
      widget.session.video &&
      widget.session.status == CallStatus.connected;

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
    if (s == CallStatus.connected && _tick == null) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _seconds++);
      });
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
        s.direction == CallDirection.outgoing &&
        s.connectedAt == null;
  }

  @override
  void dispose() {
    _tick?.cancel();
    _dismiss?.cancel();
    CallMedia.instance.remoteReady.removeListener(_onRemoteReady);
    CallMedia.instance.connectionState.removeListener(_onRemoteReady);
    super.dispose();
  }

  String get _statusLabel {
    final s = widget.session;
    switch (s.status) {
      case CallStatus.ringing:
        if (s.direction == CallDirection.incoming) {
          return s.video ? 'Incoming video call' : 'Incoming call';
        }
        return s.video ? 'Video calling…' : 'Ringing…';
      case CallStatus.connected:
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
    final showingRemoteVideo = _showVideo &&
        CallMedia.instance.remoteReady.value &&
        remoteRenderer != null;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Remote video fills the screen once it arrives; otherwise a gradient.
          if (showingRemoteVideo)
            RTCVideoView(remoteRenderer,
                objectFit:
                    RTCVideoViewObjectFit.RTCVideoViewObjectFitCover)
          else
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xFF16181C), Color(0xFF000000)],
                ),
              ),
            ),
          // Local camera preview (top-right) during a video call.
          if (_showVideo && localRenderer != null)
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
          SafeArea(
            child: Column(
              children: [
                const SizedBox(height: 44),
                if (!showingRemoteVideo) ...[
                  UserAvatar(user: session.peer, radius: 56),
                  const SizedBox(height: 20),
                ],
                Text(
                  session.peer.name,
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
              const Spacer(),
              Text(
                'End-to-end encrypted',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.45),
                  fontSize: 12.5,
                ),
              ),
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
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
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
                  CallMedia.instance.setVideoEnabled(_video);
                },
              ),
              if (_video)
                _CallControl(
                  icon: Icons.cameraswitch,
                  label: 'Flip',
                  onTap: () => CallMedia.instance.switchCamera(),
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
                      backgroundColor: AppColors.tealGreenDark,
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
