import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../state/app_lock.dart';
import '../widgets/info_section.dart';
import 'blocked_contacts_screen.dart';
import 'settings_widgets.dart';

/// Dedicated screen collecting every privacy and security control, grouped
/// into "who can see me", messaging, calls, disappearing messages, and
/// security sections.
class PrivacySettingsScreen extends StatelessWidget {
  const PrivacySettingsScreen({super.key});

  static const _disappearingOptions = <int, String>{
    0: 'Off',
    3600: '1 hour',
    86400: '24 hours',
    604800: '7 days',
    7776000: '90 days',
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy & security')),
      body: ListView(
        children: [
          const SizedBox(height: 6),
          settingsSectionLabel(context, 'Who can see my info'),
          InfoSection(children: [
            _buildLastSeenTile(),
            AudienceTile(
              icon: Icons.account_circle_outlined,
              title: 'Profile photo',
              notifier: AppState.profilePhotoAudience,
            ),
            AudienceTile(
              icon: Icons.info_outline,
              title: 'About',
              notifier: AppState.aboutAudience,
            ),
            AudienceTile(
              icon: Icons.group_add_outlined,
              title: 'Add me to groups',
              notifier: AppState.groupAddAudience,
            ),
          ]),
          settingsSectionLabel(context, 'Messaging'),
          InfoSection(children: [
            _buildContactsOnlyTile(),
            _buildReadReceiptsTile(),
            _buildTypingTile(),
          ]),
          settingsSectionLabel(context, 'Calls'),
          InfoSection(children: [_buildSilenceUnknownTile()]),
          settingsSectionLabel(context, 'Default message timer'),
          InfoSection(children: [_buildDisappearingTile(context)]),
          settingsSectionLabel(context, 'Security'),
          InfoSection(children: [
            _AppLockTile(),
            _buildBlockScreenshotsTile(),
            InfoTile(
              leading: const Icon(Icons.block_outlined),
              title: 'Blocked contacts',
              subtitle: 'Manage who can\'t reach you',
              trailing: _BlockedCountBadge(),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const BlockedContactsScreen()),
              ),
            ),
          ]),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildLastSeenTile() {
    return ValueListenableBuilder<bool>(
      valueListenable: AppState.shareLastSeen,
      builder: (context, share, _) => SwitchListTile(
        secondary: Icon(share ? Icons.visibility : Icons.visibility_off),
        title: const Text('Share online status'),
        subtitle: Text(share
            ? 'Contacts you chat with can see when you\'re online'
            : 'Your online status is hidden'),
        value: share,
        shape: kSettingsTileShape,
        onChanged: (on) => AppState.shareLastSeen.value = on,
      ),
    );
  }

  Widget _buildContactsOnlyTile() {
    return ValueListenableBuilder<bool>(
      valueListenable: AppState.messagesFromContactsOnly,
      builder: (context, on, _) => SwitchListTile(
        secondary:
            Icon(on ? Icons.mark_email_read_outlined : Icons.mail_outline),
        title: const Text('Only my contacts can message me'),
        subtitle: Text(on
            ? 'Messages from unknown numbers are ignored'
            : 'Anyone can start a chat with you'),
        value: on,
        shape: kSettingsTileShape,
        onChanged: (v) => AppState.messagesFromContactsOnly.value = v,
      ),
    );
  }

  Widget _buildReadReceiptsTile() {
    return ValueListenableBuilder<bool>(
      valueListenable: AppState.sendReadReceipts,
      builder: (context, on, _) => SwitchListTile(
        secondary: Icon(on ? Icons.done_all : Icons.remove_done),
        title: const Text('Read receipts'),
        subtitle: Text(on
            ? 'Senders can see when you\'ve read their messages'
            : 'You won\'t send read receipts (you also won\'t see others\')'),
        value: on,
        shape: kSettingsTileShape,
        onChanged: (v) => AppState.sendReadReceipts.value = v,
      ),
    );
  }

  Widget _buildTypingTile() {
    return ValueListenableBuilder<bool>(
      valueListenable: AppState.sendTypingIndicators,
      builder: (context, on, _) => SwitchListTile(
        secondary: Icon(on ? Icons.more_horiz : Icons.do_not_disturb_on),
        title: const Text('Typing indicators'),
        subtitle: Text(on
            ? 'Show others when you\'re typing'
            : 'Others won\'t see when you\'re typing'),
        value: on,
        shape: kSettingsTileShape,
        onChanged: (v) => AppState.sendTypingIndicators.value = v,
      ),
    );
  }

  Widget _buildSilenceUnknownTile() {
    return ValueListenableBuilder<bool>(
      valueListenable: AppState.silenceUnknownCallers,
      builder: (context, on, _) => SwitchListTile(
        secondary: Icon(on ? Icons.phone_disabled : Icons.phone_in_talk),
        title: const Text('Silence unknown callers'),
        subtitle: Text(on
            ? 'Only people you\'ve chatted with can ring you'
            : 'Anyone can call you'),
        value: on,
        shape: kSettingsTileShape,
        onChanged: (v) => AppState.silenceUnknownCallers.value = v,
      ),
    );
  }

  Widget _buildBlockScreenshotsTile() {
    return ValueListenableBuilder<bool>(
      valueListenable: AppState.blockScreenshots,
      builder: (context, on, _) => SwitchListTile(
        secondary: Icon(on ? Icons.screenshot_monitor : Icons.screenshot),
        title: const Text('Block screenshots'),
        subtitle: Text(on
            ? 'App contents are hidden in the switcher (on supported devices)'
            : 'Screenshots and previews are allowed'),
        value: on,
        shape: kSettingsTileShape,
        onChanged: (v) => AppState.blockScreenshots.value = v,
      ),
    );
  }

  Widget _buildDisappearingTile(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: AppState.defaultDisappearingSeconds,
      builder: (context, seconds, _) => ListTile(
        shape: kSettingsTileShape,
        leading: const Icon(Icons.timer_outlined),
        title: const Text('Default for new chats'),
        subtitle: Text(seconds == 0
            ? 'New chats keep messages until you delete them'
            : 'New chats disappear after ${_disappearingOptions[seconds] ?? '$seconds s'}'),
        trailing: const Icon(Icons.chevron_right, color: Colors.grey),
        onTap: () => _pickDisappearing(context),
      ),
    );
  }

  Future<void> _pickDisappearing(BuildContext context) async {
    final chosen = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final entry in _disappearingOptions.entries)
              ListTile(
                title: Text(entry.value),
                trailing: entry.key == AppState.defaultDisappearingSeconds.value
                    ? Icon(Icons.check,
                        color: Theme.of(sheetContext).colorScheme.primary)
                    : null,
                onTap: () => Navigator.of(sheetContext).pop(entry.key),
              ),
          ],
        ),
      ),
    );
    if (chosen != null) AppState.defaultDisappearingSeconds.value = chosen;
  }
}

/// App-lock toggle plus a "Change PIN" action when a PIN is set.
class _AppLockTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: AppLock.instance.enabled,
      builder: (context, on, _) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SwitchListTile(
            secondary: Icon(on ? Icons.lock : Icons.lock_open),
            title: const Text('App lock'),
            subtitle: Text(on
                ? 'A PIN is required to open the app'
                : 'Require a PIN to open the app'),
            value: on,
            shape: kSettingsTileShape,
            onChanged: (v) {
              if (v) {
                _setPin(context, changing: false);
              } else {
                AppLock.instance.disable();
              }
            },
          ),
          if (on)
            ListTile(
              shape: kSettingsTileShape,
              leading: const Icon(Icons.pin_outlined),
              title: const Text('Change PIN'),
              trailing: const Icon(Icons.chevron_right, color: Colors.grey),
              onTap: () => _setPin(context, changing: true),
            ),
        ],
      ),
    );
  }

  Future<void> _setPin(BuildContext context, {required bool changing}) async {
    final pin = TextEditingController();
    final confirm = TextEditingController();
    String? error;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setState) {
          Widget field(TextEditingController c, String label) => TextField(
                controller: c,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 6,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(labelText: label, counterText: ''),
              );
          return AlertDialog(
            title: Text(changing ? 'Change PIN' : 'Set a PIN'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                field(pin, 'PIN (4-6 digits)'),
                field(confirm, 'Confirm PIN'),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(error!,
                        style: const TextStyle(color: Colors.red)),
                  ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () {
                  if (pin.text.length < 4) {
                    setState(() => error = 'Use at least 4 digits');
                  } else if (pin.text != confirm.text) {
                    setState(() => error = 'PINs don\'t match');
                  } else {
                    Navigator.of(dialogContext).pop(true);
                  }
                },
                child: const Text('Set'),
              ),
            ],
          );
        },
      ),
    );
    if (ok == true) {
      await AppLock.instance.setPin(pin.text);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(changing ? 'PIN changed' : 'App lock enabled')),
        );
      }
    }
    pin.dispose();
    confirm.dispose();
  }
}

/// A small pill showing how many contacts are blocked.
class _BlockedCountBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Set<String>>(
      valueListenable: AppState.blockedContacts,
      builder: (context, blocked, _) {
        if (blocked.isEmpty) {
          return const Icon(Icons.chevron_right, color: Colors.grey);
        }
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${blocked.length}',
                style: TextStyle(color: Colors.grey.shade500)),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right, color: Colors.grey),
          ],
        );
      },
    );
  }
}
