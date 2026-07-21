import 'dart:async';

import 'package:flutter/material.dart';

import '../models/user.dart';
import '../widgets/user_avatar.dart';

/// A simulated outgoing call screen. It shows "Ringing…" briefly, then a
/// running call timer, with mute / speaker / video / end controls. Nothing
/// real is dialled — this is a UI demo — and "End" pops the screen.
class CallScreen extends StatefulWidget {
  final AppUser user;
  final bool video;

  const CallScreen({super.key, required this.user, this.video = false});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  Timer? _connectTimer;
  Timer? _tick;
  bool _connected = false;
  int _seconds = 0;
  bool _muted = false;
  bool _speaker = false;
  late bool _video = widget.video;

  @override
  void initState() {
    super.initState();
    _connectTimer = Timer(const Duration(milliseconds: 2200), () {
      if (!mounted) return;
      setState(() => _connected = true);
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _seconds++);
      });
    });
  }

  @override
  void dispose() {
    _connectTimer?.cancel();
    _tick?.cancel();
    super.dispose();
  }

  String get _status {
    if (!_connected) return widget.video ? 'Video calling…' : 'Ringing…';
    final m = _seconds ~/ 60;
    final s = _seconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF075E54), Color(0xFF0B141A)],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 40),
              UserAvatar(user: widget.user, radius: 56),
              const SizedBox(height: 20),
              Text(
                widget.user.name,
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
                    widget.video ? Icons.videocam : Icons.call,
                    size: 16,
                    color: Colors.white70,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _status,
                    style: const TextStyle(color: Colors.white70, fontSize: 16),
                  ),
                ],
              ),
              const Spacer(),
              Text(
                'End-to-end encrypted',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5),
                  fontSize: 12.5,
                ),
              ),
              const SizedBox(height: 24),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: Row(
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
                      onTap: () => setState(() => _video = !_video),
                    ),
                    _CallControl(
                      icon: _muted ? Icons.mic_off : Icons.mic,
                      active: _muted,
                      onTap: () => setState(() => _muted = !_muted),
                    ),
                    _CallControl(
                      icon: Icons.call_end,
                      background: Colors.red,
                      onTap: () => Navigator.of(context).maybePop(),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 36),
            ],
          ),
        ),
      ),
    );
  }
}

class _CallControl extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool active;
  final Color? background;

  const _CallControl({
    required this.icon,
    required this.onTap,
    this.active = false,
    this.background,
  });

  @override
  Widget build(BuildContext context) {
    final bg = background ??
        (active ? Colors.white : Colors.white.withValues(alpha: 0.18));
    final fg = background != null
        ? Colors.white
        : (active ? const Color(0xFF075E54) : Colors.white);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 60,
        height: 60,
        decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
        child: Icon(icon, color: fg, size: 26),
      ),
    );
  }
}
