import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models/user.dart';
import '../state/session.dart';
import '../widgets/user_avatar.dart';

/// Lets the current user customize their profile: display name, username,
/// avatar color, and an "about" / status line (with quick presets).
class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  late final TextEditingController _name;
  late final TextEditingController _about;
  late final TextEditingController _username;
  late String _avatarColor;

  /// Common status presets offered as one-tap chips.
  static const _statusPresets = [
    'Available',
    'Busy',
    'At work',
    'In a meeting',
    'At the gym',
    'Sleeping',
    'Battery about to die',
    'Can\'t talk, message only',
  ];

  @override
  void initState() {
    super.initState();
    final p = AppState.profile.value;
    _name = TextEditingController(text: p.name);
    _about = TextEditingController(text: p.about);
    _username = TextEditingController(text: p.username);
    _avatarColor = p.avatarColor;
  }

  @override
  void dispose() {
    _name.dispose();
    _about.dispose();
    _username.dispose();
    super.dispose();
  }

  /// A throwaway user built from the live form values, so the avatar preview
  /// updates as the name and color change.
  AppUser get _preview => AppUser(
        id: AppState.profile.value.id,
        name: _name.text.trim().isEmpty ? 'You' : _name.text,
        avatarColor: _avatarColor,
        about: _about.text,
        phone: AppState.profile.value.phone,
        username: _username.text,
      );

  Future<void> _save() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    if (Session.instance.isSignedIn) {
      await Session.instance.updateProfile(
        name: _name.text,
        about: _about.text,
        username: _username.text,
        avatarColor: _avatarColor,
      );
    } else {
      AppState.updateProfile(
        name: _name.text,
        about: _about.text,
        username: _username.text,
        avatarColor: _avatarColor,
      );
    }
    navigator.pop();
    messenger.showSnackBar(
      const SnackBar(content: Text('Profile updated')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit profile'),
        actions: [
          IconButton(icon: const Icon(Icons.check), onPressed: _save),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(child: UserAvatar(user: _preview, radius: 48)),
          const SizedBox(height: 20),
          _sectionLabel(context, 'Avatar color'),
          _ColorPicker(
            selected: _avatarColor,
            onSelected: (hex) => setState(() => _avatarColor = hex),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'Name',
              prefixIcon: Icon(Icons.person_outline),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _username,
            autocorrect: false,
            enableSuggestions: false,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'Username',
              prefixText: '@',
              helperText: 'Letters, numbers, . and _ — people can find you by this',
              prefixIcon: Icon(Icons.alternate_email),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _about,
            maxLines: 3,
            maxLength: 139,
            decoration: const InputDecoration(
              labelText: 'About',
              prefixIcon: Icon(Icons.info_outline),
              border: OutlineInputBorder(),
            ),
          ),
          _sectionLabel(context, 'Quick status'),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final s in _statusPresets)
                ActionChip(
                  label: Text(s),
                  onPressed: () => setState(() => _about.text = s),
                ),
            ],
          ),
          if (AppState.profile.value.phone.isNotEmpty) ...[
            const SizedBox(height: 20),
            TextField(
              enabled: false,
              controller:
                  TextEditingController(text: AppState.profile.value.phone),
              decoration: const InputDecoration(
                labelText: 'Phone number',
                helperText: 'Your login number — stays on this device',
                prefixIcon: Icon(Icons.phone_outlined),
                border: OutlineInputBorder(),
              ),
            ),
          ],
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save),
            label: const Text('Save'),
          ),
        ],
      ),
    );
  }

  static Widget _sectionLabel(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
        child: Text(
          text.toUpperCase(),
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.7,
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.7),
          ),
        ),
      );
}

/// A wrapping grid of avatar-color swatches with a check on the selected one.
class _ColorPicker extends StatelessWidget {
  final String selected;
  final ValueChanged<String> onSelected;
  const _ColorPicker({required this.selected, required this.onSelected});

  Color _color(String hex) {
    var h = hex.replaceFirst('#', '');
    if (h.length == 6) h = 'FF$h';
    return Color(int.tryParse(h, radix: 16) ?? 0xFF9E9E9E);
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        for (final hex in AppState.avatarPalette)
          GestureDetector(
            onTap: () => onSelected(hex),
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: _color(hex),
                shape: BoxShape.circle,
                border: hex.toUpperCase() == selected.toUpperCase()
                    ? Border.all(
                        color: Theme.of(context).colorScheme.primary, width: 3)
                    : null,
              ),
              child: hex.toUpperCase() == selected.toUpperCase()
                  ? const Icon(Icons.check, color: Colors.white, size: 22)
                  : null,
            ),
          ),
      ],
    );
  }
}
