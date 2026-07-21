import 'package:flutter/material.dart';

import '../data/mock_data.dart';
import '../models/call.dart';
import '../models/user.dart';
import '../theme/app_theme.dart';
import '../utils/date_formatter.dart';
import '../widgets/user_avatar.dart';

/// The "Calls" tab: a modern layout with a search pill, favourites, and the
/// recent call log.
class CallsTab extends StatelessWidget {
  const CallsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final calls = MockData.calls();
    final favourites = MockData.contacts().take(3).toList();
    return ListView(
      children: [
        const _SearchPill(),
        const _CreateCallLinkTile(),
        const _SectionHeader('Favourites'),
        ...favourites.map((u) => _FavouriteTile(user: u)),
        const _SectionHeader('Recent'),
        ...calls.map((c) => _CallTile(record: c)),
        const SizedBox(height: 12),
      ],
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
      trailing: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.call, color: AppColors.tealGreenDark),
          SizedBox(width: 22),
          Icon(Icons.videocam, color: AppColors.tealGreenDark),
        ],
      ),
      onTap: () {},
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
      trailing: Icon(
        record.type == CallType.video ? Icons.videocam : Icons.call,
        color: AppColors.tealGreenDark,
      ),
      onTap: () {},
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
