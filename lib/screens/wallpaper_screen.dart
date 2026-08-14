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
          // Both listenables, even on the per-chat screen: this chat's own
          // choice comes from the store, but the DEFAULT tile has to paint
          // the app-wide wallpaper, which lives in AppState.
          ListenableBuilder(
            listenable: Listenable.merge(
                [AppState.chatWallpaper, ChatStore.instance]),
            builder: (context, _) {
              final global = AppState.chatWallpaper.value;
              final current = chatId == null
                  ? global
                  : ChatStore.instance.wallpaperFor(chatId!);
              // What "Default" actually means here. On the app-wide screen it
              // is the theme's own background; in ONE chat it means "follow
              // the app-wide wallpaper" — so when that is a colour, the tile
              // has to BE that colour. It used to paint the scaffold black
              // regardless, which told somebody who had already set a
              // wallpaper that their default was black. It was not.
              final defaultFill =
                  chatId == null ? null : global;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  GridView.count(
                    crossAxisCount: 3,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: 16,
                    crossAxisSpacing: 16,
                    children: [
                      for (final color in _options)
                        _Swatch(
                          color: color,
                          defaultFill: defaultFill,
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
                  ),
                  const SizedBox(height: 12),
                  // Said in words as well as drawn. A tick on a tile is the
                  // whole confirmation otherwise, and on a pale tile in dark
                  // mode that was the thing nobody could see.
                  Text(
                    current == null
                        ? (chatId == null
                            ? 'Using the default background.'
                            : 'Following the app-wide wallpaper.')
                        : (chatId == null
                            ? 'Wallpaper set. Every chat without its own '
                                'follows this.'
                            : 'Wallpaper set for this chat only.'),
                    style: TextStyle(
                        fontSize: 12.5, color: AppColors.subtle(context)),
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

/// One wallpaper choice.
///
/// **Everything drawn ON the swatch takes the SWATCH's own colours, never the
/// app accent** — the third instance of the bug the "A bubble's contents take
/// the BUBBLE's colours" rule exists to stop, and the first one nobody was
/// looking for. Both marks used to be `AppColors.accentOn(context)`, which is
/// a colour chosen against the app BACKGROUND: near-white in dark mode. Six
/// of the twelve wallpapers here are pale, so in dark mode picking one drew a
/// white tick on a cream tile and a white 3-point border INSIDE a cream tile —
/// invisible both times. The wallpaper really changed; the picker just never
/// looked like it had, which is exactly the "no visual feedback" report.
///
/// So: the tick is drawn in [onSwatch] — computed from this tile's own
/// luminance, the same `computeLuminance() > 0.5` test `MessageBubble` uses
/// for a custom bubble colour — and sits in a filled disc of the swatch's
/// opposite, so it reads at a glance rather than needing to be found. The
/// selection RING moved OUTSIDE the tile, onto the page background, where the
/// app accent is the right colour by definition; `Border.all` is painted
/// inside a box's own bounds, which is why the old one was landing on the
/// wallpaper it was supposed to be marking.
class _Swatch extends StatelessWidget {
  final Color? color;
  final bool selected;
  final VoidCallback onTap;

  /// What the DEFAULT tile stands for, when that is not the theme's own
  /// background: on a per-chat screen it is the app-wide wallpaper this chat
  /// falls back to. Null means the theme background, which is the app-wide
  /// screen's own answer.
  final Color? defaultFill;

  const _Swatch({
    required this.color,
    required this.selected,
    required this.onTap,
    this.defaultFill,
  });

  @override
  Widget build(BuildContext context) {
    final isDefault = color == null;
    final fill = color ??
        defaultFill ??
        Theme.of(context).scaffoldBackgroundColor;
    final onSwatch =
        fill.computeLuminance() > 0.5 ? const Color(0xFF0F1419) : Colors.white;
    final ring = AppColors.accentOn(context);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Container(
        // The ring lives out here, on the page's background, with a gap so it
        // reads as a ring around the tile rather than a border on it.
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: selected ? ring : Colors.transparent,
            width: 2.5,
          ),
        ),
        child: Container(
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(AppRadius.sm),
            // A hairline of the tile's OWN contrast colour, so a pale swatch
            // has an edge on a dark page and a dark one has an edge on a
            // light page. A fixed `Colors.black12` gave the dark swatches no
            // edge at all in dark mode.
            border: Border.all(color: onSwatch.withValues(alpha: 0.18)),
          ),
          alignment: Alignment.center,
          child: isDefault
              ? Text('Default',
                  style:
                      TextStyle(fontWeight: FontWeight.w600, color: onSwatch))
              : (selected
                  ? Container(
                      padding: const EdgeInsets.all(5),
                      decoration: BoxDecoration(
                        color: onSwatch,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(Icons.check, size: 18, color: fill),
                    )
                  : null),
        ),
      ),
    );
  }
}
