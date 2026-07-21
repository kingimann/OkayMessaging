import 'package:flutter/material.dart';

import '../data/mock_data.dart';
import '../models/call.dart';
import '../theme/app_theme.dart';
import '../utils/date_formatter.dart';
import '../widgets/user_avatar.dart';

/// The "Calls" tab showing the call log.
class CallsTab extends StatelessWidget {
  const CallsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final calls = MockData.calls();
    return ListView(
      children: [
        const _CreateCallLinkTile(),
        const _SectionHeader('Recent'),
        ...calls.map((c) => _CallTile(record: c)),
      ],
    );
  }
}

class _CreateCallLinkTile extends StatelessWidget {
  const _CreateCallLinkTile();

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: CircleAvatar(
        radius: 26,
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
      leading: UserAvatar(user: record.user, radius: 26),
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
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Colors.grey,
        ),
      ),
    );
  }
}
