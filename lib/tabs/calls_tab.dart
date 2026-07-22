import 'package:flutter/material.dart';

import '../data/mock_data.dart';
import '../models/call.dart';
import '../models/user.dart';
import '../state/call_log.dart';
import '../state/call_service.dart' show CallService;
import '../theme/app_theme.dart';
import '../utils/date_formatter.dart';
import '../widgets/user_avatar.dart';

void _startCall(BuildContext context, AppUser user, {required bool video}) {
  CallService.instance.startOutgoing(user, video: video);
}

/// The "Calls" tab: a search pill, favourites, and the real, persisted call
/// log that fills in as you place and receive calls.
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
    final favourites = MockData.contacts().take(3).toList();
    return ListenableBuilder(
      listenable: CallLog.instance,
      builder: (context, _) {
        final calls = CallLog.instance.records;
        return ListView(
          children: [
            const _SearchPill(),
            const _CreateCallLinkTile(),
            const _SectionHeader('Favourites'),
            ...favourites.map((u) => _FavouriteTile(user: u)),
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
            const SizedBox(height: 12),
          ],
        );
      },
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

class _SearchPill extends StatelessWidget {
  const _SearchPill();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        decoration: BoxDecoration(
          color: isDark ? AppColors.darkAppBar : const Color(0xFFF0F2F3),
          borderRadius: BorderRadius.circular(24),
        ),
        child: const Row(
          children: [
            Icon(Icons.search, size: 22, color: Colors.grey),
            SizedBox(width: 12),
            Text('Search', style: TextStyle(color: Colors.grey, fontSize: 15)),
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
        radius: 24,
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

class _FavouriteTile extends StatelessWidget {
  final AppUser user;

  const _FavouriteTile({required this.user});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: UserAvatar(user: user, radius: 24),
      title:
          Text(user.name, style: const TextStyle(fontWeight: FontWeight.w600)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.call, color: AppColors.tealGreenDark),
            onPressed: () => _startCall(context, user, video: false),
          ),
          IconButton(
            icon: const Icon(Icons.videocam, color: AppColors.tealGreenDark),
            onPressed: () => _startCall(context, user, video: true),
          ),
        ],
      ),
      onTap: () => _startCall(context, user, video: false),
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

class _SectionHeader extends StatelessWidget {
  final String label;

  const _SectionHeader(this.label);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: Colors.grey,
        ),
      ),
    );
  }
}
