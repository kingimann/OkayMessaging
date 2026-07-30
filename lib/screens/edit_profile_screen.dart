import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models/user.dart';
import '../state/score_store.dart';
import '../state/session.dart';
import '../theme/app_theme.dart';
import '../widgets/app_shell.dart';
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
  late final TextEditingController _pronouns;
  late final TextEditingController _link;
  late String _avatarColor;
  late String _emoji;

  /// A small set of emojis offered for the avatar.
  static const _emojiChoices = [
    '😀',
    '😎',
    '🥳',
    '🤖',
    '👾',
    '🐶',
    '🐱',
    '🦊',
    '🐼',
    '🦁',
    '🐸',
    '🦄',
    '🌸',
    '🔥',
    '⚡',
    '🌈',
    '⭐',
    '🎧',
    '🎮',
    '⚽',
    '🍕',
    '☕',
    '🚀',
    '💜',
  ];

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
    _pronouns = TextEditingController(text: p.pronouns);
    _link = TextEditingController(text: p.link);
    _avatarColor = p.avatarColor;
    _emoji = p.emoji;
  }

  @override
  void dispose() {
    _name.dispose();
    _about.dispose();
    _username.dispose();
    _pronouns.dispose();
    _link.dispose();
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
        emoji: _emoji,
        pronouns: _pronouns.text,
        link: _link.text,
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
        emoji: _emoji,
        pronouns: _pronouns.text,
        link: _link.text,
      );
    } else {
      AppState.updateProfile(
        name: _name.text,
        about: _about.text,
        username: _username.text,
        avatarColor: _avatarColor,
        emoji: _emoji,
        pronouns: _pronouns.text,
        link: _link.text,
      );
    }
    if (_username.text.trim().isNotEmpty || _emoji.isNotEmpty) {
      ScoreStore.instance.recordFlag('profile_set');
    }
    navigator.pop();
    messenger.showSnackBar(
      const SnackBar(content: Text('Profile updated')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardColor =
        isDark ? const Color(0xFF23262B) : const Color(0xFFF4F6F7);

    // Borderless rows inside a card, instead of a tower of outlined boxes —
    // the whole profile fits on one screen.
    Widget field(
      TextEditingController controller, {
      required IconData icon,
      required String label,
      String? hint,
      String? prefixText,
      int maxLines = 1,
      int? maxLength,
      TextInputType? keyboardType,
      TextCapitalization capitalization = TextCapitalization.none,
    }) {
      return TextField(
        controller: controller,
        maxLines: maxLines,
        maxLength: maxLength,
        keyboardType: keyboardType,
        textCapitalization: capitalization,
        autocorrect: keyboardType == null,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          prefixText: prefixText,
          counterText: '',
          prefixIcon: Icon(icon, size: 20),
          filled: false,
          isDense: true,
          border: InputBorder.none,
          focusedBorder: InputBorder.none,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
      );
    }

    Widget card(List<Widget> children) => Material(
          color: cardColor,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) const Divider(height: 1, indent: 46),
                children[i],
              ],
            ],
          ),
        );

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: const SidebarButton(),
        title: const Text('Edit profile'),
        actions: [
          IconButton(
              icon: const Icon(Icons.check), tooltip: 'Save', onPressed: _save),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          // Tapping the avatar opens the look editor (colour + emoji) in a
          // sheet, so the pickers stop eating half the screen.
          Center(
            child: GestureDetector(
              onTap: _editAvatar,
              child: Stack(
                children: [
                  UserAvatar(user: _preview, radius: 46),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: CircleAvatar(
                      radius: 14,
                      backgroundColor: AppColors.accentOn(context),
                      child: Icon(Icons.edit,
                          size: 14, color: AppColors.onAccent(context)),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Center(
            child: TextButton(
              onPressed: _editAvatar,
              child: const Text('Change look'),
            ),
          ),
          const SizedBox(height: 6),
          card([
            field(_name,
                icon: Icons.person_outline,
                label: 'Name',
                capitalization: TextCapitalization.words),
            field(_username,
                icon: Icons.alternate_email,
                label: 'Username',
                hint: 'letters, numbers, . and _',
                keyboardType: TextInputType.text),
          ]),
          const SizedBox(height: 12),
          card([
            field(_about,
                icon: Icons.info_outline,
                label: 'About',
                maxLines: 2,
                maxLength: 139,
                capitalization: TextCapitalization.sentences),
          ]),
          // One-tap presets ride under About as a single scrolling row.
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(vertical: 6),
              children: [
                for (final preset in _statusPresets)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ActionChip(
                      label:
                          Text(preset, style: const TextStyle(fontSize: 12.5)),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => setState(() => _about.text = preset),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          card([
            field(_pronouns,
                icon: Icons.badge_outlined,
                label: 'Pronouns',
                hint: 'she/her · he/him · they/them'),
            field(_link,
                icon: Icons.link,
                label: 'Link',
                hint: 'yourwebsite.com',
                keyboardType: TextInputType.url),
          ]),
          if (AppState.profile.value.phone.isNotEmpty) ...[
            const SizedBox(height: 12),
            card([
              ListTile(
                dense: true,
                leading: const Icon(Icons.phone_outlined, size: 20),
                title: Text(AppState.profile.value.phone,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle:
                    const Text('Your login number — stays on this device'),
              ),
            ]),
          ],
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.check),
            label: const Text('Save'),
          ),
        ],
      ),
    );
  }

  /// The avatar look — colour and emoji — edited together in one sheet.
  Future<void> _editAvatar() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(child: UserAvatar(user: _preview, radius: 40)),
                const SizedBox(height: 14),
                _sectionLabel(sheetContext, 'AVATAR COLOR'),
                _ColorPicker(
                  selected: _avatarColor,
                  onSelected: (hex) {
                    setState(() => _avatarColor = hex);
                    setSheetState(() {});
                  },
                ),
                const SizedBox(height: 14),
                _sectionLabel(sheetContext, 'AVATAR EMOJI'),
                _EmojiPicker(
                  selected: _emoji,
                  choices: _emojiChoices,
                  onSelected: (e) {
                    setState(() => _emoji = e);
                    setSheetState(() {});
                  },
                ),
              ],
            ),
          ),
        ),
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

/// A wrapping grid of emoji choices for the avatar, with a "none" option that
/// falls back to the initials.
class _EmojiPicker extends StatelessWidget {
  final String selected;
  final List<String> choices;
  final ValueChanged<String> onSelected;
  const _EmojiPicker({
    required this.selected,
    required this.choices,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    Widget cell(
            {required Widget child,
            required bool active,
            required VoidCallback onTap}) =>
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              border: active ? Border.all(color: primary, width: 3) : null,
            ),
            child: child,
          ),
        );
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        cell(
          active: selected.isEmpty,
          onTap: () => onSelected(''),
          child: Icon(Icons.block, color: Colors.grey.shade500, size: 20),
        ),
        for (final e in choices)
          cell(
            active: e == selected,
            onTap: () => onSelected(e),
            child: Text(e, style: const TextStyle(fontSize: 22)),
          ),
      ],
    );
  }
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
