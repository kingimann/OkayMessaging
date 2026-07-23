import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models/user.dart';
import '../widgets/info_section.dart';
import 'okay_pro_screen.dart';
import 'settings_widgets.dart';
import 'wallpaper_screen.dart';

/// Appearance and chat-composition preferences: theme, message text size,
/// wallpaper, and Enter-to-send.
class ChatsSettingsScreen extends StatelessWidget {
  const ChatsSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Chats & appearance')),
      body: ListView(
        children: [
          const SizedBox(height: 6),
          settingsSectionLabel(context, 'Appearance'),
          const InfoSection(children: [
            _ThemeModeTile(),
            _TextSizeTile(),
          ]),
          settingsSectionLabel(context, 'Chats'),
          InfoSection(children: [
            InfoTile(
              leading: const Icon(Icons.wallpaper_outlined),
              title: 'Chat wallpaper',
              subtitle: 'Background for your conversations',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const WallpaperScreen()),
              ),
            ),
            const _BubbleColorTile(),
            _buildEnterToSendTile(),
          ]),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildEnterToSendTile() {
    return ValueListenableBuilder<bool>(
      valueListenable: AppState.enterToSend,
      builder: (context, on, _) => SwitchListTile(
        secondary: const Icon(Icons.keyboard_return),
        title: const Text('Enter key sends'),
        subtitle:
            Text(on ? 'Return sends the message' : 'Return adds a new line'),
        value: on,
        shape: kSettingsTileShape,
        onChanged: (v) => AppState.enterToSend.value = v,
      ),
    );
  }
}

/// Lets Okay Pro members pick a custom color for their own message bubbles.
/// For non-Pro users the tile shows a lock and offers to upgrade.
class _BubbleColorTile extends StatelessWidget {
  const _BubbleColorTile();

  /// Colors offered in the picker (plus a "default" reset chip).
  static const List<Color> _palette = [
    Color(0xFF25D366), // Okay green
    Color(0xFF0A84FF), // blue
    Color(0xFF7A5CFF), // Pro purple
    Color(0xFFEB4B7E), // pink
    Color(0xFFFF8A3D), // orange
    Color(0xFF00BFA5), // teal
    Color(0xFFEF5350), // red
    Color(0xFF5C6BC0), // indigo
    Color(0xFF8D6E63), // brown
    Color(0xFF455A64), // slate
  ];

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppUser>(
      valueListenable: AppState.profile,
      builder: (context, user, _) {
        final isPro = user.verified;
        return ValueListenableBuilder<Color?>(
          valueListenable: AppState.bubbleColor,
          builder: (context, color, _) => InfoTile(
            leading: const Icon(Icons.color_lens_outlined),
            title: 'Chat bubble color',
            subtitle: isPro
                ? (color == null
                    ? 'Default green'
                    : 'Custom color for your messages')
                : 'An Okay Pro perk',
            trailing: isPro
                ? Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: color ?? _palette.first,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.black12),
                    ),
                  )
                : const Icon(Icons.lock_outline, color: Colors.grey, size: 20),
            onTap: () =>
                isPro ? _pickColor(context, color) : _offerUpgrade(context),
          ),
        );
      },
    );
  }

  Future<void> _offerUpgrade(BuildContext context) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Custom bubble colors'),
        content: const Text(
          'Personalize the color of your own message bubbles with Okay Pro.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('See Okay Pro'),
          ),
        ],
      ),
    );
    if (go == true && context.mounted) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const OkayProScreen()),
      );
    }
  }

  Future<void> _pickColor(BuildContext context, Color? current) async {
    final chosen = await showModalBottomSheet<_ColorChoice>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Bubble color',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              const SizedBox(height: 16),
              Wrap(
                spacing: 14,
                runSpacing: 14,
                children: [
                  for (final c in _palette)
                    GestureDetector(
                      onTap: () => Navigator.of(sheetContext)
                          .pop(_ColorChoice(c)),
                      child: Container(
                        width: 46,
                        height: 46,
                        decoration: BoxDecoration(
                          color: c,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: current == c
                                ? Theme.of(sheetContext).colorScheme.primary
                                : Colors.black12,
                            width: current == c ? 3 : 1,
                          ),
                        ),
                        child: current == c
                            ? const Icon(Icons.check, color: Colors.white)
                            : null,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 18),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => Navigator.of(sheetContext)
                      .pop(const _ColorChoice(null)),
                  icon: const Icon(Icons.restart_alt),
                  label: const Text('Reset to default green'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (chosen != null) AppState.bubbleColor.value = chosen.color;
  }
}

/// A nullable-color result from the bubble-color sheet (null = reset).
class _ColorChoice {
  final Color? color;
  const _ColorChoice(this.color);
}

/// A three-way theme selector (System / Light / Dark) as a segmented control.
class _ThemeModeTile extends StatelessWidget {
  const _ThemeModeTile();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppState.themeMode,
      builder: (context, mode, _) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(_iconFor(mode),
                    color: Theme.of(context).iconTheme.color, size: 22),
                const SizedBox(width: 14),
                const Text('Theme',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<ThemeMode>(
                segments: const [
                  ButtonSegment(
                      value: ThemeMode.system,
                      icon: Icon(Icons.brightness_auto),
                      label: Text('System')),
                  ButtonSegment(
                      value: ThemeMode.light,
                      icon: Icon(Icons.light_mode),
                      label: Text('Light')),
                  ButtonSegment(
                      value: ThemeMode.dark,
                      icon: Icon(Icons.dark_mode),
                      label: Text('Dark')),
                ],
                selected: {mode},
                showSelectedIcon: false,
                onSelectionChanged: (s) => AppState.themeMode.value = s.first,
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _iconFor(ThemeMode m) => switch (m) {
        ThemeMode.system => Icons.brightness_auto,
        ThemeMode.light => Icons.light_mode,
        ThemeMode.dark => Icons.dark_mode,
      };
}

/// A slider that scales message text, with a live sample bubble.
class _TextSizeTile extends StatelessWidget {
  const _TextSizeTile();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: AppState.messageTextScale,
      builder: (context, scale, _) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.format_size,
                      color: Theme.of(context).iconTheme.color, size: 22),
                  const SizedBox(width: 14),
                  const Text('Message text size',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
                  const Spacer(),
                  Text('${(scale * 100).round()}%',
                      style: TextStyle(color: Colors.grey.shade500)),
                ],
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  margin: const EdgeInsets.only(top: 6, bottom: 2),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                  decoration: BoxDecoration(
                    color: isDark
                        ? const Color(0xFF2A2D34)
                        : const Color(0xFFE7ECEF),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    'Aa — the quick brown fox',
                    textScaler: TextScaler.linear(scale),
                    style: const TextStyle(fontSize: 16, height: 1.35),
                  ),
                ),
              ),
              Slider(
                value: scale,
                min: 0.85,
                max: 1.30,
                divisions: 9,
                label: '${(scale * 100).round()}%',
                onChanged: (v) => AppState.messageTextScale.value =
                    double.parse(v.toStringAsFixed(2)),
              ),
            ],
          ),
        );
      },
    );
  }
}
