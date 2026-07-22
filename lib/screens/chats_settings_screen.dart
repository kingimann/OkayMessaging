import 'package:flutter/material.dart';

import '../app_state.dart';
import '../widgets/info_section.dart';
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
