import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../state/status_store.dart';
import '../utils/date_formatter.dart';

Color _hex(String s) {
  var h = s.replaceFirst('#', '');
  if (h.length == 6) h = 'FF$h';
  return Color(int.tryParse(h, radix: 16) ?? 0xFF7A5CFF);
}

String _initials(String name) {
  final parts = name.trim().split(RegExp(r'\s+'));
  if (parts.isEmpty || parts.first.isEmpty) return '?';
  if (parts.length == 1) return parts.first[0].toUpperCase();
  return (parts.first[0] + parts.last[0]).toUpperCase();
}

/// The Status list: your own status plus recent updates from contacts.
class StatusScreen extends StatelessWidget {
  const StatusScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Status')),
      body: AnimatedBuilder(
        animation: StatusStore.instance,
        builder: (context, _) {
          final me = AppState.profile.value;
          final mine = StatusStore.instance.myActive();
          final others = StatusStore.instance.otherThreads();
          return ListView(
            children: [
              ListTile(
                leading: _RingAvatar(
                  name: me.name,
                  colorHex: me.avatarColor,
                  active: mine.isNotEmpty,
                  showAdd: mine.isEmpty,
                ),
                title: const Text('My status',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(mine.isEmpty
                    ? 'Tap to add a status update'
                    : '${mine.length} update${mine.length == 1 ? '' : 's'} · '
                        '${DateFormatter.callLabel(mine.last.time)}'),
                trailing: IconButton(
                  icon: const Icon(Icons.add_circle_outline),
                  tooltip: 'Add status',
                  onPressed: () => _compose(context),
                ),
                onTap: () {
                  if (mine.isEmpty) {
                    _compose(context);
                  } else {
                    _view(
                      context,
                      StatusThread(
                        authorId: me.id,
                        authorName: 'My status',
                        avatarColor: me.avatarColor,
                        updates: mine,
                      ),
                    );
                  }
                },
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
                child: Text('RECENT UPDATES',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.6,
                        color: Colors.grey.shade500)),
              ),
              if (others.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 20),
                  child: Text('No recent updates',
                      style: TextStyle(color: Colors.grey.shade500)),
                )
              else
                for (final t in others)
                  ListTile(
                    leading: _RingAvatar(
                        name: t.authorName,
                        colorHex: t.avatarColor,
                        active: true),
                    title: Text(t.authorName,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(DateFormatter.callLabel(t.latest)),
                    onTap: () => _view(context, t),
                  ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _compose(context),
        child: const Icon(Icons.edit),
      ),
    );
  }

  void _compose(BuildContext context) => Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const StatusComposerScreen()));

  void _view(BuildContext context, StatusThread thread) =>
      Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => StatusViewerScreen(thread: thread)));
}

/// An avatar with a colored ring (Snapchat/WhatsApp-style unseen indicator).
class _RingAvatar extends StatelessWidget {
  final String name;
  final String colorHex;
  final bool active;
  final bool showAdd;
  const _RingAvatar({
    required this.name,
    required this.colorHex,
    this.active = false,
    this.showAdd = false,
  });

  @override
  Widget build(BuildContext context) {
    final avatar = CircleAvatar(
      radius: 22,
      backgroundColor: _hex(colorHex),
      child: Text(_initials(name),
          style: const TextStyle(
              color: Colors.white, fontWeight: FontWeight.w600)),
    );
    Widget core = active
        ? Container(
            padding: const EdgeInsets.all(2.5),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFF12B76A), width: 2.5),
            ),
            child: avatar,
          )
        : avatar;
    if (showAdd) {
      core = Stack(
        clipBehavior: Clip.none,
        children: [
          avatar,
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                shape: BoxShape.circle,
                border: Border.all(
                    color: Theme.of(context).scaffoldBackgroundColor,
                    width: 2),
              ),
              child: const Icon(Icons.add, size: 15, color: Colors.white),
            ),
          ),
        ],
      );
    }
    return core;
  }
}

/// Compose a text status on a colored background.
class StatusComposerScreen extends StatefulWidget {
  const StatusComposerScreen({super.key});

  @override
  State<StatusComposerScreen> createState() => _StatusComposerScreenState();
}

class _StatusComposerScreenState extends State<StatusComposerScreen> {
  final _controller = TextEditingController();
  String _bg = StatusStore.palette.first;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _post() {
    if (_controller.text.trim().isEmpty) return;
    final me = AppState.profile.value;
    StatusStore.instance.post(
      text: _controller.text,
      bgColor: _bg,
      authorName: me.name,
      avatarColor: me.avatarColor,
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _hex(_bg),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          TextButton(
            onPressed: _post,
            child: const Text('Post',
                style: TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: TextField(
                  controller: _controller,
                  autofocus: true,
                  textAlign: TextAlign.center,
                  maxLines: null,
                  maxLength: 240,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.w600),
                  cursorColor: Colors.white,
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    counterText: '',
                    hintText: 'Type a status…',
                    hintStyle: TextStyle(color: Colors.white70),
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (final c in StatusStore.palette)
                    GestureDetector(
                      onTap: () => setState(() => _bg = c),
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 5),
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: _hex(c),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: c == _bg ? Colors.white : Colors.white24,
                            width: c == _bg ? 3 : 1,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Full-screen tap-through viewer for one author's status thread.
class StatusViewerScreen extends StatefulWidget {
  final StatusThread thread;
  const StatusViewerScreen({super.key, required this.thread});

  @override
  State<StatusViewerScreen> createState() => _StatusViewerScreenState();
}

class _StatusViewerScreenState extends State<StatusViewerScreen> {
  int _i = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _restartTimer();
  }

  void _restartTimer() {
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 4), _next);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _next() {
    if (_i < widget.thread.updates.length - 1) {
      setState(() => _i++);
      _restartTimer();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  void _prev() {
    if (_i > 0) {
      setState(() => _i--);
      _restartTimer();
    }
  }

  @override
  Widget build(BuildContext context) {
    final updates = widget.thread.updates;
    final u = updates[_i];
    return Scaffold(
      backgroundColor: _hex(u.bgColor),
      body: GestureDetector(
        onTapUp: (d) {
          final w = MediaQuery.of(context).size.width;
          if (d.globalPosition.dx < w / 3) {
            _prev();
          } else {
            _next();
          }
        },
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                child: Row(
                  children: [
                    for (var j = 0; j < updates.length; j++)
                      Expanded(
                        child: Container(
                          height: 3,
                          margin: const EdgeInsets.symmetric(horizontal: 2),
                          decoration: BoxDecoration(
                            color: j <= _i
                                ? Colors.white
                                : Colors.white.withValues(alpha: 0.35),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 18,
                      backgroundColor: _hex(widget.thread.avatarColor),
                      child: Text(_initials(widget.thread.authorName),
                          style: const TextStyle(
                              color: Colors.white, fontSize: 14)),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(widget.thread.authorName,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600)),
                          Text(DateFormatter.callLabel(u.time),
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 12)),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Text(
                      u.text,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 26,
                          fontWeight: FontWeight.w600,
                          height: 1.3),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
