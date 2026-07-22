import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models/user.dart';
import '../theme/app_theme.dart';
import '../widgets/info_section.dart';
import '../widgets/user_avatar.dart';
import 'media_gallery_screen.dart';
import 'security_code_screen.dart';

/// A modern contact detail screen: a clean surface header with a large
/// avatar, tonal action buttons, and grouped info sections.
class ContactInfoScreen extends StatelessWidget {
  final AppUser user;

  /// When set, a "Media, links, and docs" tile opens that chat's gallery.
  final String? chatId;

  const ContactInfoScreen({super.key, required this.user, this.chatId});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        actions: [
          PopupMenuButton<String>(
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'share', child: Text('Share')),
              PopupMenuItem(value: 'edit', child: Text('Edit')),
            ],
          ),
        ],
      ),
      body: ListView(
        children: [
          const SizedBox(height: 8),
          Center(
            child: UserAvatar(
              user: user,
              radius: 56,
              heroTag: 'chatHeaderAvatar',
            ),
          ),
          const SizedBox(height: 14),
          Center(
            child: Text(
              user.name,
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          if (user.handle.isNotEmpty) ...[
            const SizedBox(height: 4),
            Center(
              child: Text(
                user.handle,
                style: const TextStyle(
                  color: AppColors.tealGreenDark,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
          if (user.phone.isNotEmpty) ...[
            const SizedBox(height: 4),
            Center(
              child: Text(
                user.phone,
                style: TextStyle(color: Colors.grey.shade600, fontSize: 15),
              ),
            ),
          ],
          const SizedBox(height: 22),
          const _ActionButtons(),
          const SizedBox(height: 20),
          InfoSection(
            children: [
              InfoTile(
                title: 'About',
                subtitle: user.about,
              ),
            ],
          ),
          if (chatId != null)
            InfoSection(
              children: [
                InfoTile(
                  leading: const Icon(Icons.photo_library_outlined),
                  title: 'Media, links, and docs',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => MediaGalleryScreen(
                        chatId: chatId!,
                        contactName: user.name,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          InfoSection(
            children: [
              const InfoTile(
                leading: Icon(Icons.notifications_outlined),
                title: 'Notifications',
                subtitle: 'On',
              ),
              InfoTile(
                leading: const Icon(Icons.lock_outline),
                title: 'Encryption',
                subtitle: 'Tap to verify the security code',
                trailing: const Icon(Icons.chevron_right, color: Colors.grey),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => SecurityCodeScreen(contact: user),
                  ),
                ),
              ),
              const InfoTile(
                leading: Icon(Icons.wallpaper_outlined),
                title: 'Wallpaper & sound',
              ),
            ],
          ),
          ValueListenableBuilder<Set<String>>(
            valueListenable: AppState.blockedContacts,
            builder: (context, _, __) {
              final blocked = AppState.isBlocked(user.phone);
              return InfoSection(
                children: [
                  InfoTile(
                    leading: Icon(blocked ? Icons.check_circle_outline : Icons.block,
                        color: blocked ? null : Colors.red),
                    title:
                        blocked ? 'Unblock ${user.name}' : 'Block ${user.name}',
                    titleColor: blocked ? null : Colors.red,
                    onTap: () => _toggleBlock(context, blocked),
                  ),
                  InfoTile(
                    leading: const Icon(Icons.thumb_down_outlined,
                        color: Colors.red),
                    title: 'Report ${user.name}',
                    titleColor: Colors.red,
                    onTap: () => _report(context),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Future<void> _toggleBlock(BuildContext context, bool blocked) async {
    if (blocked) {
      AppState.setBlocked(user.phone, false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('${user.name} unblocked')));
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Block ${user.name}?'),
        content: Text(
            'You won\'t be able to send messages to ${user.name} until you '
            'unblock them.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Block', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      AppState.setBlocked(user.phone, true);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('${user.name} blocked')));
    }
  }

  void _report(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${user.name} reported')),
    );
  }
}

class _ActionButtons extends StatelessWidget {
  const _ActionButtons();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          Expanded(child: _TonalAction(icon: Icons.message, label: 'Message')),
          SizedBox(width: 10),
          Expanded(child: _TonalAction(icon: Icons.call, label: 'Audio')),
          SizedBox(width: 10),
          Expanded(child: _TonalAction(icon: Icons.videocam, label: 'Video')),
        ],
      ),
    );
  }
}

class _TonalAction extends StatelessWidget {
  final IconData icon;
  final String label;

  const _TonalAction({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: isDark
          ? AppColors.tealGreenDark.withValues(alpha: 0.22)
          : AppColors.tealGreenDark.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () {},
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            children: [
              Icon(icon, color: AppColors.tealGreenDark, size: 22),
              const SizedBox(height: 4),
              Text(
                label,
                style: const TextStyle(
                  color: AppColors.tealGreenDark,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
