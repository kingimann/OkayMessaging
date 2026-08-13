import 'package:flutter/material.dart';

import '../app_state.dart';
import '../state/chat_store.dart';
import '../state/message_sound_store.dart';
import '../theme/app_theme.dart';

/// A simple chat-wallpaper picker: choose a solid background color (or the
/// default). With no [chatId] the choice is the global default for every
/// conversation; with a [chatId] it overrides the wallpaper for just that chat.
class WallpaperScreen extends StatelessWidget {
  /// When set, the picker changes only this chat's wallpaper.
  final String? chatId;

  const WallpaperScreen({super.key, this.chatId});

  // null = default (theme-based) wallpaper.
  static const List<Color?> _options = [
    null,
    Color(0xFFEFEAE2),
    Color(0xFFD9E4DD),
    Color(0xFFF3E1D6),
    Color(0xFFDCEBF5),
    Color(0xFFEDE1F0),
    Color(0xFFF6E7C4),
    Color(0xFF0B141A),
    Color(0xFF1F2C34),
    Color(0xFF2A3942),
    Color(0xFF3B2E4A),
    Color(0xFF14342B),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(chatId == null ? 'Chat wallpaper & sound' : 'Wallpaper & sound'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          AnimatedBuilder(
            animation: chatId == null
                ? AppState.chatWallpaper
                : ChatStore.instance,
            builder: (context, _) {
              final current = chatId == null
                  ? AppState.chatWallpaper.value
                  : ChatStore.instance.wallpaperFor(chatId!);
              return GridView.count(
                crossAxisCount: 3,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 16,
                crossAxisSpacing: 16,
                children: [
                  for (final color in _options)
                    _Swatch(
                      color: color,
                      selected: color == current,
                      onTap: () {
                        if (chatId == null) {
                          AppState.chatWallpaper.value = color;
                        } else {
                          ChatStore.instance.setWallpaper(chatId!, color);
                        }
                      },
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 28),
          _MessageSoundSection(chatId: chatId),
        ],
      ),
    );
  }
}

/// Which built-in tone plays for a message that arrives while THIS chat is
/// open (with no [chatId], the app-wide default every chat falls back to).
/// Deliberately narrow — see [MessageSoundStore]'s doc comment for why it
/// can't touch the lock-screen/background notification sound.
class _MessageSoundSection extends StatelessWidget {
  final String? chatId;
  const _MessageSoundSection({required this.chatId});

  @override
  Widget build(BuildContext context) {
    final store = MessageSoundStore.instance;
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        final current =
            chatId == null ? store.defaultSound : store.overrideFor(chatId!);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Message sound',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(
              chatId == null
                  ? 'Plays while a chat is open and a message arrives in '
                      'it — not the lock-screen notification sound, which '
                      'stays the standard one.'
                  : 'Overrides the app-wide default for this chat only.',
              style: TextStyle(fontSize: 12.5, color: AppColors.subtle(context)),
            ),
            const SizedBox(height: 8),
            // A plain ListTile with its own checkmark, not RadioListTile —
            // its group API is deprecated in this Flutter (see
            // form_fill_screen.dart's choice chips for the same call).
            if (chatId != null)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('Default (${store.defaultSound.label})'),
                trailing: current == null
                    ? Icon(Icons.check, color: AppColors.accentOn(context))
                    : null,
                onTap: () => store.setForChat(chatId!, null),
              ),
            for (final s in MessageSound.values)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(s.label),
                leading: IconButton(
                  icon: const Icon(Icons.play_arrow),
                  tooltip: 'Preview',
                  onPressed: () => store.previewSound(s),
                ),
                trailing: current == s
                    ? Icon(Icons.check, color: AppColors.accentOn(context))
                    : null,
                onTap: () {
                  if (chatId == null) {
                    store.setDefault(s);
                  } else {
                    store.setForChat(chatId!, s);
                  }
                },
              ),
          ],
        );
      },
    );
  }
}

class _Swatch extends StatelessWidget {
  final Color? color;
  final bool selected;
  final VoidCallback onTap;

  const _Swatch({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDefault = color == null;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        decoration: BoxDecoration(
          color: color ?? Theme.of(context).scaffoldBackgroundColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? AppColors.accentOn(context) : Colors.black12,
            width: selected ? 3 : 1,
          ),
        ),
        alignment: Alignment.center,
        child: isDefault
            ? const Text('Default',
                style: TextStyle(fontWeight: FontWeight.w600))
            : (selected
                ? Icon(Icons.check, color: AppColors.accentOn(context))
                : null),
      ),
    );
  }
}
