import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'package:flutter/services.dart';

import '../mesh/mesh_service.dart';
import '../app_state.dart';
import '../state/account_service.dart';
import '../state/app_lock.dart';
import '../state/two_step.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/info_section.dart';
import 'blocked_contacts_screen.dart';
import 'settings_widgets.dart';
import 'two_step_screen.dart';

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
          settingsSectionLabel(context, 'How people can reach you'),
          const InfoSection(children: [_ReachabilityTiles()]),
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
          settingsSectionLabel(context, 'Nearby'),
          const InfoSection(children: [_MeshTile()]),
          settingsSectionLabel(context, 'Messaging'),
          InfoSection(children: [
            _buildContactsOnlyTile(),
            _buildReadReceiptsTile(),
            _buildTypingTile(),
          ]),
          settingsSectionLabel(context, 'Spam & bots'),
          InfoSection(children: [
            _buildBlockLinksTile(),
            _buildSpamKeywordsTile(context),
          ]),
          settingsSectionLabel(context, 'Calls'),
          InfoSection(children: [_buildSilenceUnknownTile()]),
          settingsSectionLabel(context, 'Default message timer'),
          InfoSection(children: [_buildDisappearingTile(context)]),
          settingsSectionLabel(context, 'Security'),
          InfoSection(children: [
            _TwoStepTile(),
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

  Widget _buildBlockLinksTile() {
    return ValueListenableBuilder<bool>(
      valueListenable: AppState.blockLinksFromStrangers,
      builder: (context, on, _) => SwitchListTile(
        secondary: const Icon(Icons.link_off),
        title: const Text('Block links from strangers'),
        subtitle: const Text(
            'Silently drop messages with links from people you '
            'haven\'t chatted with'),
        value: on,
        shape: kSettingsTileShape,
        onChanged: (v) => AppState.blockLinksFromStrangers.value = v,
      ),
    );
  }

  Widget _buildSpamKeywordsTile(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: AppState.spamKeywords,
      builder: (context, keywords, _) => ListTile(
        leading: const Icon(Icons.filter_alt_outlined),
        title: const Text('Blocked keywords'),
        subtitle: Text(
          keywords.trim().isEmpty
              ? 'Messages containing these words are dropped'
              : keywords,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: const Icon(Icons.chevron_right),
        shape: kSettingsTileShape,
        onTap: () => _editKeywords(context, keywords),
      ),
    );
  }

  Future<void> _editKeywords(BuildContext context, String current) async {
    final result = await showAppTextPrompt(
      context,
      icon: Icons.shield_outlined,
      title: 'Blocked keywords',
      message: 'Comma-separated. Incoming messages containing any of these '
          'words are dropped before they reach you.',
      hint: 'crypto, free money, click here',
      initial: current,
      maxLines: 3,
      allowEmpty: true,
    );
    if (result != null) AppState.spamKeywords.value = result.trim();
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

/// Entry to the two-step verification management screen.
class _TwoStepTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: TwoStepVerification.instance.enabled,
      builder: (context, on, _) => ListTile(
        shape: kSettingsTileShape,
        leading: Icon(on ? Icons.verified_user : Icons.shield_outlined),
        title: const Text('Two-step verification'),
        subtitle: Text(on
            ? 'On — a PIN is required to sign in'
            : 'Add a PIN required to sign in'),
        trailing: const Icon(Icons.chevron_right, color: Colors.grey),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const TwoStepScreen()),
        ),
      ),
    );
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
                style: TextStyle(color: AppColors.subtle(context))),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right, color: Colors.grey),
          ],
        );
      },
    );
  }
}


/// The two doors to this account — profile search and contact sync — as
/// switches backed by the directory row itself, so the choice applies on
/// every other phone's searches, not just this one's screen.
class _ReachabilityTiles extends StatefulWidget {
  const _ReachabilityTiles();

  @override
  State<_ReachabilityTiles> createState() => _ReachabilityTilesState();
}

class _ReachabilityTilesState extends State<_ReachabilityTiles> {
  bool? _byUsername;
  bool? _byPhone;
  bool _saving = false;
  String? _note;

  @override
  void initState() {
    super.initState();
    AccountService.instance.getReachability().then((r) {
      if (!mounted) return;
      setState(() {
        _byUsername = r.$1;
        _byPhone = r.$2;
      });
    });
  }

  Future<void> _apply({bool? byUsername, bool? byPhone}) async {
    final u = byUsername ?? _byUsername ?? true;
    final p = byPhone ?? _byPhone ?? true;
    setState(() {
      _byUsername = u;
      _byPhone = p;
      _saving = true;
      _note = null;
    });
    final ok = await AccountService.instance
        .setReachability(byUsername: u, byPhone: p);
    if (!mounted) return;
    setState(() {
      _saving = false;
      // An unsaved choice must not look chosen — say it, and re-read what
      // the directory actually holds.
      _note = ok ? null : 'Couldn\'t save — check your connection.';
    });
    if (!ok) {
      final r = await AccountService.instance.getReachability();
      if (mounted) {
        setState(() {
          _byUsername = r.$1;
          _byPhone = r.$2;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final loading = _byUsername == null;
    return Column(
      children: [
        SwitchListTile.adaptive(
          secondary: const Icon(Icons.alternate_email),
          title: const Text('By profile'),
          subtitle: const Text(
              'Appear in username search, so people can message your '
              'profile without knowing your number'),
          value: _byUsername ?? true,
          onChanged: loading || _saving
              ? null
              : (v) => _apply(byUsername: v),
        ),
        SwitchListTile.adaptive(
          secondary: const Icon(Icons.dialpad),
          title: const Text('By phone number'),
          subtitle: const Text(
              'Appear when someone who has your number syncs their '
              'contacts'),
          value: _byPhone ?? true,
          onChanged: loading || _saving ? null : (v) => _apply(byPhone: v),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              _note ??
                  'Controls being found. People you already chat with keep '
                  'the conversation either way.',
              style: TextStyle(
                  fontSize: 12,
                  color: _note == null
                      ? Theme.of(context).colorScheme.onSurfaceVariant
                      : Theme.of(context).colorScheme.error),
            ),
          ),
        ),
      ],
    );
  }
}

/// Bluetooth mesh: messages to people near you when there is no internet.
///
/// Off by default, and it says what it costs. Turning it on means this phone
/// carries other people's messages as well as its own — which is the deal that
/// makes a mesh work, and not one to make on somebody's behalf without telling
/// them. What it cannot do is read any of them: a message is sealed before it
/// reaches the radio, exactly as it is before it reaches the server.
class _MeshTile extends StatefulWidget {
  const _MeshTile();

  @override
  State<_MeshTile> createState() => _MeshTileState();
}

class _MeshTileState extends State<_MeshTile> {
  bool? _available;

  @override
  void initState() {
    super.initState();
    MeshService.instance.available.then((ok) {
      if (mounted) setState(() => _available = ok);
    });
  }

  @override
  Widget build(BuildContext context) {
    // Nothing at all rather than a switch that cannot move. Most devices
    // running this — every browser, for a start — have no peripheral role to
    // offer, and a disabled toggle is a promise the app cannot keep.
    if (_available == false) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: MeshService.instance,
      builder: (context, _) {
        final mesh = MeshService.instance;
        return SwitchListTile(
          secondary: Icon(mesh.enabled
              ? Icons.bluetooth_connected
              : Icons.bluetooth_outlined),
          title: const Text('Message people nearby'),
          subtitle: Text(_subtitle(mesh)),
          value: mesh.enabled,
          shape: kSettingsTileShape,
          onChanged: _available == null ? null : mesh.setEnabled,
        );
      },
    );
  }

  String _subtitle(MeshService mesh) {
    if (!mesh.enabled) {
      return 'Off. Turn on to send and receive over Bluetooth with no '
          'internet — your phone also passes on other people\'s messages, '
          'sealed, without being able to read them.';
    }
    if (!mesh.running) return 'Starting…';
    if (mesh.peers == 0) return 'On. No one nearby yet.';
    return 'On. ${mesh.peers} ${mesh.peers == 1 ? 'phone' : 'phones'} nearby.';
  }
}
