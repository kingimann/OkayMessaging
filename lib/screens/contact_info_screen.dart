import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../models/chat.dart';
import '../models/user.dart';
import '../state/call_service.dart';
import '../state/chat_store.dart';
import '../state/favourites_store.dart';
import '../state/follow_store.dart';
import '../state/payment_security_store.dart';
import '../state/platform_moderation.dart';
import 'marketplace_screen.dart' show SellerShopButton;
import 'public_feed_screen.dart' show openPublicProfile;
import '../state/session.dart' as local;
import '../theme/app_theme.dart';
import '../util/account_code.dart';
import '../util/file_saver.dart';
import '../utils/chat_transcript.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/info_section.dart';
import '../widgets/user_avatar.dart';
import '../widgets/verified_badge.dart';
import 'chat_places_screen.dart';
import 'media_gallery_screen.dart';
import 'security_code_screen.dart';
import 'wallpaper_screen.dart';

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
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    user.name,
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                if (user.verified) ...[
                  const SizedBox(width: 6),
                  const VerifiedBadge(size: 22),
                ],
              ],
            ),
          ),
          if (user.score > 0) ...[
            const SizedBox(height: 8),
            Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: BoxDecoration(
                  color: const Color(0xFF7A5CFF).withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.local_fire_department,
                        size: 16, color: Color(0xFF7A5CFF)),
                    const SizedBox(width: 4),
                    Text('${user.score} Okay Score',
                        style: const TextStyle(
                            color: Color(0xFF7A5CFF),
                            fontWeight: FontWeight.w600,
                            fontSize: 13)),
                  ],
                ),
              ),
            ),
          ],
          if (user.handle.isNotEmpty) ...[
            const SizedBox(height: 4),
            Center(
              child: Text(
                user.handle,
                style: TextStyle(
                  color: AppColors.accentOn(context),
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
          if (user.pronouns.trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            Center(
              child: Text(
                user.pronouns.trim(),
                style: TextStyle(color: AppColors.subtle(context), fontSize: 13),
              ),
            ),
          ],
          if (user.isBusiness) ...[
            const SizedBox(height: 6),
            Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: BoxDecoration(
                  color: AppColors.accentOn(context).withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.storefront_outlined,
                        size: 15, color: AppColors.accentOn(context)),
                    const SizedBox(width: 4),
                    Text(
                      user.businessCategory.trim().isEmpty
                          ? 'Business'
                          : user.businessCategory.trim(),
                      style: TextStyle(
                          color: AppColors.accentOn(context),
                          fontWeight: FontWeight.w600,
                          fontSize: 13),
                    ),
                  ],
                ),
              ),
            ),
            if (user.businessHours.trim().isNotEmpty) ...[
              const SizedBox(height: 4),
              Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.schedule_outlined,
                        size: 14, color: AppColors.subtle(context)),
                    const SizedBox(width: 3),
                    Text(
                      user.businessHours.trim(),
                      style: TextStyle(
                          color: AppColors.subtle(context), fontSize: 13),
                    ),
                  ],
                ),
              ),
            ],
            // What the storefront actually stocks: a button into their
            // active listings, as far as this device has seen them.
            // Nothing when none — the widget itself keeps that promise.
            Center(
                child: SellerShopButton(
                    username: user.username, sellerName: user.name)),
          ],
          if (user.location.trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.place_outlined,
                      size: 14, color: AppColors.subtle(context)),
                  const SizedBox(width: 3),
                  Text(
                    user.location.trim(),
                    style: TextStyle(
                        color: AppColors.subtle(context), fontSize: 13),
                  ),
                ],
              ),
            ),
          ],
          if (user.link.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.link,
                      size: 15,
                      color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 4),
                  Text(
                    user.link.trim(),
                    style: TextStyle(
                        fontSize: 13.5,
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ],
          if (user.username.isNotEmpty) ...[
            const SizedBox(height: 12),
            Center(
              child: ListenableBuilder(
                listenable: FollowStore.instance,
                builder: (context, _) {
                  final following =
                      FollowStore.instance.isFollowing(user.username);
                  return Column(
                    children: [
                      following
                          ? OutlinedButton.icon(
                              onPressed: () =>
                                  FollowStore.instance.toggle(user.username),
                              icon: const Icon(Icons.check, size: 18),
                              label: const Text('Following'),
                            )
                          : FilledButton.icon(
                              onPressed: () =>
                                  FollowStore.instance.toggle(user.username),
                              icon: const Icon(Icons.person_add_alt_1,
                                  size: 18),
                              label: const Text('Follow'),
                            ),
                    ],
                  );
                },
              ),
            ),
          ],
          if (user.phone.isNotEmpty) ...[
            const SizedBox(height: 4),
            Center(
              // Grouped and labelled when it is a code rather than a number.
              // Twelve bare digits under somebody's name reads as a phone
              // number that has gone wrong.
              child: Text(
                AccountCode.isCode(user.phone)
                    ? 'Code ${AccountCode.pretty(user.phone)}'
                    : user.phone,
                style: TextStyle(color: AppColors.subtle(context), fontSize: 15),
              ),
            ),
          ],
          const SizedBox(height: 22),
          _ActionButtons(
            onMessage: () => Navigator.of(context).maybePop(),
            onCall: () => _startCall(context, video: false),
            onVideo: () => _startCall(context, video: true),
            // The person's PROFILE — posts, follows, the newsfeed face of
            // them — which chat previously had no road to at all. Only when
            // they have a handle: the profile is keyed by username, and a
            // contact without one has no profile to open, so no dead button.
            onProfile: user.isGroup || user.username.trim().isEmpty
                ? null
                : () => openPublicProfile(context, user.username,
                    name: user.name),
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
          // Star this person for one-tap calling from the Calls tab.
          if (!user.isGroup && user.phone.isNotEmpty)
            ListenableBuilder(
              listenable: FavouritesStore.instance,
              builder: (context, _) {
                final fav = FavouritesStore.instance.isFavourite(user.id);
                return InfoSection(children: [
                  InfoTile(
                    leading: Icon(fav ? Icons.star : Icons.star_outline,
                        color: fav ? const Color(0xFFF1C40F) : null),
                    title: fav
                        ? 'Favourite'
                        : 'Add to call favourites',
                    trailing: Switch(
                      value: fav,
                      onChanged: (_) =>
                          FavouritesStore.instance.toggle(user),
                    ),
                  ),
                ]);
              },
            ),
          if (chatId != null)
            InfoSection(
              children: [
                InfoTile(
                  leading: const Icon(Icons.photo_library_outlined),
                  title: 'Pinboard — media, links, places, files',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => MediaGalleryScreen(
                        chatId: chatId!,
                        contactName: user.name,
                      ),
                    ),
                  ),
                ),
                // Moved off the chat's overflow menu with it. This is a thing
                // you decide about a PERSON — reach them the other way —
                // rather than about the message you are part-way through, so
                // it belongs on the screen about them.
                if (!user.isGroup && user.phone.isNotEmpty)
                  InfoTile(
                    leading: const Icon(Icons.sms_outlined),
                    title: 'Send as text (SMS)',
                    subtitle: 'Hands the number to your phone\'s own '
                        'Messages app',
                    onTap: () => launchUrl(Uri.parse('sms:${user.phone}')),
                  ),
              ],
            ),
          if (chatId != null) _ConfirmBeforeSendSection(chatId: chatId!),
          // The chat's own settings, moved here from the overflow menu so
          // everything about this conversation lives on one screen.
          if (chatId != null) _ChatSettingsSection(chatId: chatId!, user: user),
          // Notes never leave this device, so there is no second device to
          // compare a security code with.
          if (user.id != 'self')
            InfoSection(
              children: [
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
              ],
            ),
          if (chatId != null) _ChatDangerSection(chatId: chatId!),
          // Your own notes: there is nobody to block or report. Offering it
          // would only mean blocking yourself.
          if (user.id != 'self')
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
    buf.write('\nMessage me on OkayMessenger.');
    Clipboard.setData(ClipboardData(text: buf.toString()));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Contact copied to clipboard')),
    );
  }

  /// Renames this contact locally (does not affect what they call themselves).
  Future<void> _editName(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final newName = await showAppTextPrompt(
      context,
      icon: Icons.drive_file_rename_outline,
      title: 'Edit name',
      initial: user.name,
      capitalization: TextCapitalization.words,
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
    final ok = await showAppConfirmDialog(
      context,
      icon: Icons.block,
      title: 'Block ${user.name}?',
      message: 'You won\'t be able to send messages to ${user.name} until '
          'you unblock them.',
      confirmLabel: 'Block',
      destructive: true,
    );
    if (ok && context.mounted) {
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
                            color: AppColors.subtle(context), fontSize: 13)),
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
    if (reason == null) return;
    // ACTUALLY SENT. This said "has been reported" and did nothing of the
    // kind: it blocked locally and told the person their report had gone
    // somewhere. A report nobody receives is worse than no report button,
    // because it stops them from doing anything that would have worked.
    final sent = await PlatformModeration.instance.report(
      reason: reason,
      targetPhone: user.phone,
      targetHandle: user.username,
      reporterPhone: local.Session.instance.user.value?.phone ?? '',
    );
    if (alsoBlock) AppState.setBlocked(user.phone, true);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(!sent
              ? (alsoBlock
                  ? 'Blocked ${user.name}. The report couldn\'t be sent — '
                      'you may be offline.'
                  : 'Couldn\'t send that report — you may be offline.')
              : alsoBlock
                  ? 'Reported and blocked ${user.name}'
                  : 'Thanks — ${user.name} has been reported')),
    );
  }
}

/// A small dialog that owns its text controller so it is disposed only after
/// the dialog's exit transition completes.

class _ActionButtons extends StatelessWidget {
  final VoidCallback onMessage;
  final VoidCallback onCall;
  final VoidCallback onVideo;
  final VoidCallback? onProfile;

  const _ActionButtons({
    required this.onMessage,
    required this.onCall,
    required this.onVideo,
    this.onProfile,
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
          if (onProfile != null) ...[
            const SizedBox(width: 10),
            Expanded(
                child: _TonalAction(
                    icon: Icons.person_outline,
                    label: 'Profile',
                    onTap: onProfile!)),
          ],
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
          ? AppColors.accentOn(context).withValues(alpha: 0.22)
          : AppColors.accentOn(context).withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            children: [
              Icon(icon, color: AppColors.accentOn(context), size: 22),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  color: AppColors.accentOn(context),
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

/// A safety toggle: when on, sending anything in this chat asks the user to
/// confirm the recipient first — a guard against messaging the wrong person.
class _ConfirmBeforeSendSection extends StatelessWidget {
  final String chatId;
  const _ConfirmBeforeSendSection({required this.chatId});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ChatStore.instance,
      builder: (context, _) {
        final chat = ChatStore.instance.chatById(chatId);
        final on = chat?.confirmBeforeSend ?? false;
        return InfoSection(
          children: [
            SwitchListTile(
              secondary: Icon(on ? Icons.verified_user : Icons.shield_outlined),
              title: const Text('Confirm before sending'),
              subtitle: Text(on
                  ? 'You\'ll confirm the recipient before each message sends'
                  : 'Ask me to confirm before sending, to avoid mistakes'),
              value: on,
              onChanged: (v) =>
                  ChatStore.instance.setConfirmBeforeSend(chatId, v),
            ),
            SwitchListTile(
              secondary: Icon(chat?.protectContent ?? false
                  ? Icons.no_photography
                  : Icons.no_photography_outlined),
              title: const Text('Screenshot & forward protection'),
              // Says what it does AND what it cannot do. iOS gives no way to
              // stop a screenshot — only to notice one — and a toggle that
              // implied otherwise would be worse than no toggle.
              subtitle: Text(chat?.protectContent ?? false
                  ? 'Forwarding and copying are off, and screenshots are '
                      'announced in the chat. Screenshots cannot be blocked.'
                  : 'Turn off forwarding and copying, and announce '
                      'screenshots to both of you'),
              value: chat?.protectContent ?? false,
              onChanged: (v) =>
                  ChatStore.instance.setProtectContent(chatId, v),
            ),
            if (chat != null &&
                !chat.contact.isGroup &&
                chat.contact.phone.isNotEmpty)
              AnimatedBuilder(
                animation: PaymentSecurityStore.instance,
                builder: (context, _) {
                  final trusted = PaymentSecurityStore.instance
                      .isTrustedContact(chat.contact.phone);
                  return SwitchListTile(
                    secondary: Icon(
                        trusted ? Icons.handshake : Icons.handshake_outlined),
                    title: const Text('Trusted for payments'),
                    // Only meaningful with the trusted-place check on, but the
                    // mark is harmless off — it just says who you'd never be
                    // asked to verify a send to.
                    subtitle: Text(trusted
                        ? 'Sends to this contact skip the texted-code check'
                        : 'Skip the texted-code check when sending to this '
                            'contact from outside a trusted place'),
                    value: trusted,
                    onChanged: (v) => PaymentSecurityStore.instance
                        .setTrustedContact(chat.contact.phone, v),
                  );
                },
              ),
          ],
        );
      },
    );
  }
}

/// The conversation's own settings — pin, mute, disappearing messages,
/// wallpaper, shared places, export — live here instead of a long overflow
/// menu on the chat screen.
class _ChatSettingsSection extends StatelessWidget {
  final String chatId;
  final AppUser user;
  const _ChatSettingsSection({required this.chatId, required this.user});

  String _ttlLabel(int seconds) => switch (seconds) {
        0 => 'Off',
        Chat.afterViewing => 'After viewing',
        3600 => '1 hour',
        86400 => '1 day',
        604800 => '1 week',
        _ => '${seconds}s',
      };

  Future<void> _chooseDisappearing(BuildContext context) async {
    const options = <String, int>{
      'Off': 0,
      // Snapchat's signature: the conversation clears from this device once
      // you've viewed it and left.
      'After viewing': Chat.afterViewing,
      '1 hour': 3600,
      '1 day': 86400,
      '1 week': 604800,
    };
    final current =
        ChatStore.instance.chatById(chatId)?.disappearingSeconds ?? 0;
    final chosen = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Text(
                '"After viewing" clears the chat from this device when you '
                'leave it. A timer deletes new messages that long after '
                'they\'re sent. Either way, only from this device.',
                style: TextStyle(color: Colors.grey, fontSize: 13),
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final entry in options.entries)
                    ListTile(
                      title: Text(entry.key),
                      trailing: entry.value == current
                          ? Icon(Icons.check,
                              color:
                                  Theme.of(sheetContext).colorScheme.primary)
                          : null,
                      onTap: () =>
                          Navigator.of(sheetContext).pop(entry.value),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (chosen != null) ChatStore.instance.setDisappearing(chatId, chosen);
  }

  Future<void> _exportChat(BuildContext context) async {
    final chat = ChatStore.instance.chatById(chatId);
    if (chat == null) return;
    final messenger = ScaffoldMessenger.of(context);
    if (chat.messages.isEmpty) {
      messenger.showSnackBar(
          const SnackBar(content: Text('Nothing to export yet')));
      return;
    }
    final transcript =
        buildChatTranscript(chat, AppState.profile.value.name);
    final result = await saveIncomingFile(
      transcriptFileName(user.name),
      Uint8List.fromList(utf8.encode(transcript)),
    );
    messenger.showSnackBar(
        SnackBar(content: Text(result ?? 'Couldn\'t export the chat')));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ChatStore.instance,
      builder: (context, _) {
        final store = ChatStore.instance;
        final chat = store.chatById(chatId);
        if (chat == null) return const SizedBox.shrink();
        return InfoSection(
          children: [
            InfoTile(
              leading: const Icon(Icons.push_pin_outlined),
              title: 'Pin chat',
              trailing: Switch(
                value: chat.isPinned,
                onChanged: (_) => store.togglePin(chatId),
              ),
            ),
            InfoTile(
              leading: const Icon(Icons.notifications_outlined),
              title: 'Mute notifications',
              trailing: Switch(
                value: chat.isMuted,
                onChanged: (_) => store.toggleMute(chatId),
              ),
            ),
            InfoTile(
              leading: const Icon(Icons.timer_outlined),
              title: 'Disappearing messages',
              subtitle: _ttlLabel(chat.disappearingSeconds),
              onTap: () => _chooseDisappearing(context),
            ),
            InfoTile(
              leading: const Icon(Icons.wallpaper_outlined),
              title: 'Wallpaper & sound',
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => WallpaperScreen(chatId: chatId))),
            ),
            InfoTile(
              leading: const Icon(Icons.place_outlined),
              title: 'Shared places',
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ChatPlacesScreen(
                      chatId: chatId, contactName: user.name))),
            ),
            InfoTile(
              leading: const Icon(Icons.ios_share_outlined),
              title: 'Export chat',
              onTap: () => _exportChat(context),
            ),
          ],
        );
      },
    );
  }
}

/// Clear and delete, kept beside Block/Report where destructive actions
/// belong.
class _ChatDangerSection extends StatelessWidget {
  final String chatId;
  const _ChatDangerSection({required this.chatId});

  Future<bool> _confirm(BuildContext context,
          {required String title,
          required String message,
          required String action}) =>
      showAppConfirmDialog(
        context,
        icon: Icons.warning_amber_rounded,
        title: title,
        message: message,
        confirmLabel: action,
        destructive: true,
      );

  @override
  Widget build(BuildContext context) {
    return InfoSection(
      children: [
        InfoTile(
          leading: const Icon(Icons.cleaning_services_outlined,
              color: Colors.red),
          title: 'Clear chat',
          titleColor: Colors.red,
          onTap: () async {
            final ok = await _confirm(context,
                title: 'Clear this chat?',
                message:
                    'All messages in this conversation will be removed from '
                    'this device. This cannot be undone.',
                action: 'Clear chat');
            if (ok) ChatStore.instance.clearMessages(chatId);
          },
        ),
        InfoTile(
          leading: const Icon(Icons.delete_outline, color: Colors.red),
          title: 'Delete chat',
          titleColor: Colors.red,
          onTap: () async {
            final ok = await _confirm(context,
                title: 'Delete this chat?',
                message: 'This conversation will be removed from this '
                    'device. This cannot be undone.',
                action: 'Delete chat');
            if (!ok || !context.mounted) return;
            ChatStore.instance.deleteChat(chatId);
            // Leave both this screen and the now-deleted conversation.
            Navigator.of(context).popUntil((r) => r.isFirst);
          },
        ),
      ],
    );
  }
}
