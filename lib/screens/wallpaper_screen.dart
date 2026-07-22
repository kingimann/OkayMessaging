import 'package:flutter/material.dart';

import '../app_state.dart';
import '../state/chat_store.dart';
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
        title: Text(chatId == null ? 'Chat wallpaper' : 'Wallpaper'),
      ),
      body: AnimatedBuilder(
        animation: chatId == null
            ? AppState.chatWallpaper
            : ChatStore.instance,
        builder: (context, _) {
          final current = chatId == null
              ? AppState.chatWallpaper.value
              : ChatStore.instance.wallpaperFor(chatId!);
          return GridView.count(
            crossAxisCount: 3,
            padding: const EdgeInsets.all(16),
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
                    Navigator.of(context).pop();
                  },
                ),
            ],
          );
        },
      ),
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
            color: selected ? AppColors.tealGreenDark : Colors.black12,
            width: selected ? 3 : 1,
          ),
        ),
        alignment: Alignment.center,
        child: isDefault
            ? const Text('Default',
                style: TextStyle(fontWeight: FontWeight.w600))
            : (selected
                ? const Icon(Icons.check, color: AppColors.tealGreenDark)
                : null),
      ),
    );
  }
}
