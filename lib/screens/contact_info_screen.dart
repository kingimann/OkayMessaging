import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../models/user.dart';
import '../state/call_service.dart';
import '../state/chat_store.dart';
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
            onSelected: (v) {
              if (v == 'share') _shareContact(context);
              if (v == 'edit') _editName(context);
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'share', child: Text('Share')),
              PopupMenuItem(value: 'edit', child: Text('Edit name')),
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
          _ActionButtons(
            onMessage: () => Navigator.of(context).maybePop(),
            onCall: () => _startCall(context, video: false),
            onVideo: () => _startCall(context, video: true),
          ),
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

  /// Starts an outgoing call and returns to the conversation so the call UI
  /// (shown by the app root) takes over.
  void _startCall(BuildContext context, {required bool video}) {
    CallService.instance.startOutgoing(user, video: video);
    Navigator.of(context).maybePop();
  }

  /// Copies a shareable summary of this contact to the clipboard.
  void _shareContact(BuildContext context) {
    final buf = StringBuffer(user.name);
    if (user.handle.isNotEmpty) buf.write(' (${user.handle})');
    if (user.phone.isNotEmpty) buf.write('\n${user.phone}');
    buf.write('\nMessage me on Okay Messaging.');
    Clipboard.setData(ClipboardData(text: buf.toString()));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Contact copied to clipboard')),
    );
  }

  /// Renames this contact locally (does not affect what they call themselves).
  Future<void> _editName(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final newName = await showDialog<String>(
      context: context,
      builder: (_) => _EditNameDialog(initial: user.name),
    );
    if (newName != null && newName.isNotEmpty) {
      ChatStore.instance.updateContactProfile(user.id, name: newName);
      messenger.showSnackBar(const SnackBar(content: Text('Name updated')));
    }
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

  Future<void> _report(BuildContext context) async {
    const reasons = [
      'Spam or scam',
      'Harassment or bullying',
      'Inappropriate content',
      'Impersonation',
      'Something else',
    ];
    var alsoBlock = true;
    final reason = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheet) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Report ${user.name}',
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text('Choose a reason. Reports are confidential.',
                        style: TextStyle(
                            color: Colors.grey.shade600, fontSize: 13)),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              for (final r in reasons)
                ListTile(
                  title: Text(r),
                  trailing: const Icon(Icons.chevron_right, size: 20),
                  onTap: () => Navigator.pop(sheetContext, r),
                ),
              CheckboxListTile(
                value: alsoBlock,
                onChanged: (v) => setSheet(() => alsoBlock = v ?? true),
                title: Text('Also block ${user.name}'),
                controlAffinity: ListTileControlAffinity.leading,
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    if (reason == null || !context.mounted) return;
    if (alsoBlock) AppState.setBlocked(user.phone, true);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(alsoBlock
              ? 'Reported and blocked ${user.name}'
              : 'Thanks — ${user.name} has been reported')),
    );
  }
}

/// A small dialog that owns its text controller so it is disposed only after
/// the dialog's exit transition completes.
class _EditNameDialog extends StatefulWidget {
  final String initial;
  const _EditNameDialog({required this.initial});

  @override
  State<_EditNameDialog> createState() => _EditNameDialogState();
}

class _EditNameDialogState extends State<_EditNameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit name'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textCapitalization: TextCapitalization.words,
        decoration: const InputDecoration(
          labelText: 'Name',
          helperText: 'Only changes how this contact appears to you',
          border: OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _ActionButtons extends StatelessWidget {
  final VoidCallback onMessage;
  final VoidCallback onCall;
  final VoidCallback onVideo;

  const _ActionButtons({
    required this.onMessage,
    required this.onCall,
    required this.onVideo,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          Expanded(
              child: _TonalAction(
                  icon: Icons.message, label: 'Message', onTap: onMessage)),
          const SizedBox(width: 10),
          Expanded(
              child: _TonalAction(
                  icon: Icons.call, label: 'Audio', onTap: onCall)),
          const SizedBox(width: 10),
          Expanded(
              child: _TonalAction(
                  icon: Icons.videocam, label: 'Video', onTap: onVideo)),
        ],
      ),
    );
  }
}

class _TonalAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _TonalAction(
      {required this.icon, required this.label, required this.onTap});

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
        onTap: onTap,
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
