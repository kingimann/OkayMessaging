import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../state/call_media.dart';
import '../state/call_service.dart';
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
      // Show the terminal state briefly, then dismiss.
      _dismiss ??= Timer(const Duration(milliseconds: 1400), () {
        CallService.instance.clear();
      });
    }
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

  Widget _incomingControls() {
    return Row(
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
