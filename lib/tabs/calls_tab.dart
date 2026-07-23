import 'package:flutter/material.dart';

import '../data/mock_data.dart';
import '../models/call.dart';
import '../models/chat.dart';
import '../models/message.dart';
import '../models/user.dart';
import '../screens/chat_screen.dart';
import '../state/call_log.dart';
import '../state/call_service.dart' show CallService;
import '../state/chat_store.dart';
import '../theme/app_theme.dart';
import '../utils/date_formatter.dart';
import '../widgets/user_avatar.dart';

void _startCall(BuildContext context, AppUser user, {required bool video}) {
  CallService.instance.startOutgoing(user, video: video);
}

/// A received voicemail — a voicemail voice message plus the chat it lives in.
class _Voicemail {
  final Chat chat;
  final Message message;
  const _Voicemail(this.chat, this.message);
}

List<_Voicemail> _receivedVoicemails() {
  final out = <_Voicemail>[];
  for (final chat in ChatStore.instance.allChats) {
    for (final m in chat.messages) {
      if (m.isVoicemail && !m.isMe) out.add(_Voicemail(chat, m));
    }
  }
  out.sort((a, b) => b.message.time.compareTo(a.message.time));
  return out;
}

/// The "Calls" tab: a modern layout with a search field, quick-call
/// favourites, received voicemails, and the persisted call log.
class CallsTab extends StatelessWidget {
  const CallsTab({super.key});

  Future<void> _clearLog(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Clear call history?'),
        content: const Text('This removes every entry from the call log.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Clear', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (ok == true) CallLog.instance.clear();
  }

  @override
  Widget build(BuildContext context) {
    final favourites = MockData.contacts().take(5).toList();
    return ListenableBuilder(
      listenable: Listenable.merge([CallLog.instance, ChatStore.instance]),
      builder: (context, _) {
        final calls = CallLog.instance.records;
        final voicemails = _receivedVoicemails();
        return ListView(
          padding: const EdgeInsets.only(bottom: 16),
          children: [
            const _SearchField(),
            const _CreateCallLinkTile(),
            _FavouritesRow(favourites: favourites),
            if (voicemails.isNotEmpty) ...[
              const _SectionHeader('Voicemail'),
              ...voicemails.map((v) => _VoicemailTile(voicemail: v)),
            ],
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const _SectionHeader('Recent'),
                if (calls.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: TextButton(
                      onPressed: () => _clearLog(context),
                      child: const Text('Clear'),
                    ),
                  ),
              ],
            ),
            if (calls.isEmpty)
              const _EmptyRecent()
            else
              ...calls.map((c) => _CallTile(record: c)),
          ],
        );
      },
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF22252B) : const Color(0xFFF0F2F3),
          borderRadius: BorderRadius.circular(26),
        ),
        child: Row(
          children: [
            Icon(Icons.search, size: 22, color: Colors.grey.shade500),
            const SizedBox(width: 12),
            Text('Search calls',
                style: TextStyle(color: Colors.grey.shade500, fontSize: 15)),
          ],
        ),
      ),
    );
  }
}

class _CreateCallLinkTile extends StatelessWidget {
  const _CreateCallLinkTile();

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: CircleAvatar(
        radius: 22,
        backgroundColor: AppColors.tealGreenDark.withValues(alpha: 0.15),
        child: const Icon(Icons.link, color: AppColors.tealGreenDark),
      ),
      title: const Text('Create call link',
          style: TextStyle(fontWeight: FontWeight.w600)),
      subtitle: const Text('Share a link for your call'),
      onTap: () {},
    );
  }
}

/// Horizontally scrolling quick-call favourites.
class _FavouritesRow extends StatelessWidget {
  final List<AppUser> favourites;
  const _FavouritesRow({required this.favourites});

  @override
  Widget build(BuildContext context) {
    if (favourites.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader('Favourites'),
        SizedBox(
          height: 104,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: favourites.length,
            separatorBuilder: (_, __) => const SizedBox(width: 16),
            itemBuilder: (context, i) {
              final user = favourites[i];
              return GestureDetector(
                onTap: () => _startCall(context, user, video: false),
                child: SizedBox(
                  width: 66,
                  child: Column(
                    children: [
                      UserAvatar(user: user, radius: 30),
                      const SizedBox(height: 6),
                      Text(
                        user.name.split(' ').first,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12.5),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _VoicemailTile extends StatelessWidget {
  final _Voicemail voicemail;
  const _VoicemailTile({required this.voicemail});

  String get _duration {
    final s = voicemail.message.voiceSeconds;
    final m = s ~/ 60;
    final sec = s % 60;
    return '$m:${sec.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Stack(
        children: [
          UserAvatar(user: voicemail.chat.contact, radius: 24),
          Positioned(
            right: -1,
            bottom: -1,
            child: Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                color: AppColors.tealGreenDark,
                shape: BoxShape.circle,
                border: Border.all(color: Theme.of(context).canvasColor, width: 2),
              ),
              child: const Icon(Icons.voicemail, size: 11, color: Colors.white),
            ),
          ),
        ],
      ),
      title: Text(voicemail.chat.contact.name,
          style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Row(
        children: [
          Icon(Icons.voicemail, size: 15, color: Colors.grey.shade500),
          const SizedBox(width: 4),
          Text('Voicemail · $_duration'),
          const SizedBox(width: 6),
          Text('· ${DateFormatter.callLabel(voicemail.message.time)}',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 12.5)),
        ],
      ),
      trailing: IconButton(
        icon: const Icon(Icons.play_circle_fill,
            color: AppColors.tealGreenDark, size: 34),
        tooltip: 'Open voicemail',
        onPressed: () => _openChat(context),
      ),
      onTap: () => _openChat(context),
    );
  }

  void _openChat(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ChatScreen(chat: voicemail.chat)),
    );
  }
}

class _CallTile extends StatelessWidget {
  final CallRecord record;

  const _CallTile({required this.record});

  IconData get _directionIcon {
    switch (record.direction) {
      case CallDirection.incoming:
        return Icons.call_received;
      case CallDirection.outgoing:
        return Icons.call_made;
      case CallDirection.missed:
        return Icons.call_missed;
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = record.isMissed ? Colors.red : Colors.green;
    return ListTile(
      leading: UserAvatar(user: record.user, radius: 24),
      title: Text(
        record.user.name,
        style: TextStyle(
          fontWeight: FontWeight.w600,
          color: record.isMissed ? Colors.red : null,
        ),
      ),
      subtitle: Row(
        children: [
          Icon(_directionIcon, size: 16, color: color),
          const SizedBox(width: 4),
          Text(DateFormatter.callLabel(record.time)),
          if (record.durationLabel != null) ...[
            const SizedBox(width: 6),
            Icon(Icons.timer_outlined, size: 13, color: Colors.grey.shade500),
            const SizedBox(width: 2),
            Text(record.durationLabel!,
                style: TextStyle(color: Colors.grey.shade500)),
          ],
        ],
      ),
      trailing: IconButton(
        icon: Icon(
          record.type == CallType.video ? Icons.videocam : Icons.call,
          color: AppColors.tealGreenDark,
        ),
        onPressed: () =>
            _startCall(context, record.user, video: record.type == CallType.video),
      ),
      onTap: () =>
          _startCall(context, record.user, video: record.type == CallType.video),
    );
  }
}

/// Empty state for the recent-calls section before any calls happen.
class _EmptyRecent extends StatelessWidget {
  const _EmptyRecent();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
      child: Column(
        children: [
          Icon(Icons.call_outlined, size: 44, color: Colors.grey.shade400),
          const SizedBox(height: 12),
          Text('No recent calls',
              style: TextStyle(
                  fontWeight: FontWeight.w600, color: Colors.grey.shade600)),
          const SizedBox(height: 4),
          Text('Calls you make and receive will show up here.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade500, fontSize: 13)),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;

  const _SectionHeader(this.label);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
          color: Colors.grey,
        ),
      ),
    );
  }
}
