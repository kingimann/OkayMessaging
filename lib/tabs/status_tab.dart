import 'package:flutter/material.dart';

import '../data/mock_data.dart';
import '../models/status.dart';
import '../theme/app_theme.dart';
import '../utils/date_formatter.dart';
import '../widgets/user_avatar.dart';

/// The "Status" (stories) tab.
class StatusTab extends StatelessWidget {
  const StatusTab({super.key});

  @override
  Widget build(BuildContext context) {
    final statuses = MockData.statuses();
    final recent = statuses.where((s) => !s.viewed).toList();
    final viewed = statuses.where((s) => s.viewed).toList();

    return ListView(
      children: [
        _MyStatusTile(),
        if (recent.isNotEmpty) ...[
          const _SectionHeader('Recent updates'),
          ...recent.map((s) => _StatusTile(status: s)),
        ],
        if (viewed.isNotEmpty) ...[
          const _SectionHeader('Viewed updates'),
          ...viewed.map((s) => _StatusTile(status: s)),
        ],
      ],
    );
  }
}

class _MyStatusTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          const UserAvatar(user: MockData.me, radius: 26),
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.lightGreen,
                shape: BoxShape.circle,
                border: Border.all(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  width: 2,
                ),
              ),
              child: const Icon(Icons.add, size: 18, color: Colors.white),
            ),
          ),
        ],
      ),
      title: const Text('My status',
          style: TextStyle(fontWeight: FontWeight.w600)),
      subtitle: const Text('Tap to add status update'),
      onTap: () {},
    );
  }
}

class _StatusTile extends StatelessWidget {
  final StatusUpdate status;

  const _StatusTile({required this.status});

  @override
  Widget build(BuildContext context) {
    final ringColor =
        status.viewed ? Colors.grey : AppColors.lightGreen;
    return ListTile(
      leading: Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: ringColor, width: 2),
        ),
        child: UserAvatar(user: status.user, radius: 24),
      ),
      title: Text(status.user.name,
          style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(DateFormatter.statusLabel(status.time)),
      onTap: () => _showStatusViewer(context),
    );
  }

  void _showStatusViewer(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Viewing ${status.user.name}\'s status')),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;

  const _SectionHeader(this.label);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Theme.of(context).brightness == Brightness.dark
          ? AppColors.chatBgDark
          : const Color(0xFFF0F0F0),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
