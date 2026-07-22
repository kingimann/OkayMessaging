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
                  Icon(
                    session.video ? Icons.videocam : Icons.call,
                    size: 16,
                    color: Colors.white70,
                  ),
                  const SizedBox(width: 6),
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
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _CallControl(
          icon: _speaker ? Icons.volume_up : Icons.volume_up_outlined,
          active: _speaker,
          onTap: () => setState(() => _speaker = !_speaker),
        ),
        _CallControl(
          icon: _video ? Icons.videocam : Icons.videocam_off,
          active: _video,
          onTap: () {
            setState(() => _video = !_video);
            CallMedia.instance.setVideoEnabled(_video);
          },
        ),
        _CallControl(
          icon: _muted ? Icons.mic_off : Icons.mic,
          active: _muted,
          onTap: () {
            setState(() => _muted = !_muted);
            CallMedia.instance.setMuted(_muted);
          },
        ),
        _CallControl(
          icon: Icons.call_end,
          background: Colors.red,
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

  const _CallControl({
    required this.icon,
    required this.onTap,
    this.active = false,
    this.background,
    this.label,
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
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: 62,
            height: 62,
            decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
            child: Icon(icon, color: fg, size: 27),
          ),
        ),
        if (label != null) ...[
          const SizedBox(height: 8),
          Text(label!,
              style: const TextStyle(color: Colors.white70, fontSize: 13)),
        ],
      ],
    );
  }
}
