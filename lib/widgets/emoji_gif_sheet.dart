import 'package:flutter/material.dart';

import '../state/gif_service.dart';
import '../theme/app_theme.dart';
import 'emoji_data.dart';

/// What the picker sheet came back with: either an emoji to insert or a GIF
/// to send.
class PickedContent {
  final String? emoji;
  final GifResult? gif;

  const PickedContent.emoji(String this.emoji) : gif = null;
  const PickedContent.gif(GifResult this.gif) : emoji = null;
}

/// The composer's emoji + GIF picker: the full emoji catalog with categories
/// and search, and a GIF tab next to it. Used by both the chat composer and
/// the community ones so they behave the same.
Future<PickedContent?> showEmojiGifSheet(
  BuildContext context, {
  bool allowGif = true,
  int initialTab = 0,
}) {
  return showModalBottomSheet<PickedContent>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _EmojiGifSheet(allowGif: allowGif, initialTab: initialTab),
  );
}

class _EmojiGifSheet extends StatefulWidget {
  final bool allowGif;
  final int initialTab;
  const _EmojiGifSheet({required this.allowGif, required this.initialTab});

  @override
  State<_EmojiGifSheet> createState() => _EmojiGifSheetState();
}

class _EmojiGifSheetState extends State<_EmojiGifSheet>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(
    length: widget.allowGif ? 2 : 1,
    initialIndex: widget.allowGif ? widget.initialTab : 0,
    vsync: this,
  );

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.of(context).size.height * 0.62;
    return SizedBox(
      height: height,
      child: Column(
        children: [
          if (widget.allowGif)
            TabBar(
              controller: _tabs,
              labelColor: AppColors.tealGreenDark,
              indicatorColor: AppColors.tealGreenDark,
              tabs: const [
                Tab(text: 'Emoji'),
                Tab(text: 'GIF'),
              ],
            ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                EmojiPane(
                  onPick: (e) =>
                      Navigator.of(context).pop(PickedContent.emoji(e)),
                ),
                if (widget.allowGif)
                  GifPane(
                    onPick: (g) =>
                        Navigator.of(context).pop(PickedContent.gif(g)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The emoji picker: a search box over the categorised grid. Public so the
/// chat composer can show it inline instead of in a sheet.
class EmojiPane extends StatefulWidget {
  final ValueChanged<String> onPick;
  const EmojiPane({super.key, required this.onPick});

  @override
  State<EmojiPane> createState() => _EmojiPaneState();
}

class _EmojiPaneState extends State<EmojiPane> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _query.text.trim();
    final matches = EmojiData.search(q);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
          child: TextField(
            controller: _query,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Search emoji',
              prefixIcon: const Icon(Icons.search, size: 20),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24),
              ),
            ),
          ),
        ),
        Expanded(
          child: q.isNotEmpty
              ? (matches.isEmpty
                  ? const _NoResults(message: 'No emoji for that')
                  : GridView.count(
                      crossAxisCount: 8,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      children: [
                        for (final e in matches)
                          _EmojiCell(emoji: e, onTap: widget.onPick),
                      ],
                    ))
              : CustomScrollView(
                  slivers: [
                    for (final entry in EmojiData.categories.entries) ...[
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
                          child: Text(
                            entry.key.toUpperCase(),
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.6,
                              color: AppColors.subtle(context),
                            ),
                          ),
                        ),
                      ),
                      SliverPadding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        sliver: SliverGrid.count(
                          crossAxisCount: 8,
                          children: [
                            for (final e in entry.value)
                              _EmojiCell(emoji: e, onTap: widget.onPick),
                          ],
                        ),
                      ),
                    ],
                    const SliverToBoxAdapter(child: SizedBox(height: 20)),
                  ],
                ),
        ),
      ],
    );
  }
}

class _EmojiCell extends StatelessWidget {
  final String emoji;
  final ValueChanged<String> onTap;
  const _EmojiCell({required this.emoji, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onTap(emoji),
      borderRadius: BorderRadius.circular(8),
      child: Center(child: Text(emoji, style: const TextStyle(fontSize: 25))),
    );
  }
}

/// The GIF picker: trending by default, searchable, two columns.
class GifPane extends StatefulWidget {
  final ValueChanged<GifResult> onPick;
  const GifPane({super.key, required this.onPick});

  @override
  State<GifPane> createState() => _GifPaneState();
}

class _GifPaneState extends State<GifPane> {
  final _query = TextEditingController();
  List<GifResult> _results = const [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load('');
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _load(String query) async {
    if (!GifService.instance.isConfigured) return;
    setState(() => _loading = true);
    final results = await GifService.instance.search(query);
    if (!mounted) return;
    setState(() {
      _results = results;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!GifService.instance.isConfigured) return const _GifUnconfigured();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
          child: TextField(
            controller: _query,
            textInputAction: TextInputAction.search,
            onSubmitted: _load,
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Search GIFs',
              prefixIcon: const Icon(Icons.search, size: 20),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24),
              ),
            ),
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _results.isEmpty
                  ? const _NoResults(message: 'No GIFs found')
                  : GridView.builder(
                      padding: const EdgeInsets.fromLTRB(10, 0, 10, 16),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        mainAxisSpacing: 8,
                        crossAxisSpacing: 8,
                        childAspectRatio: 1.2,
                      ),
                      itemCount: _results.length,
                      itemBuilder: (context, i) {
                        final gif = _results[i];
                        return InkWell(
                          onTap: () => widget.onPick(gif),
                          borderRadius: BorderRadius.circular(10),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: Image.network(
                              gif.previewUrl,
                              fit: BoxFit.cover,
                              semanticLabel: gif.description,
                              errorBuilder: (_, __, ___) => Container(
                                color: Colors.grey.withValues(alpha: 0.2),
                                child: const Icon(Icons.gif_box_outlined),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
        ),
      ],
    );
  }
}

/// Shown when no Tenor key was compiled in — better than an empty grid that
/// looks broken.
class _GifUnconfigured extends StatelessWidget {
  const _GifUnconfigured();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.gif_box_outlined, size: 44, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            const Text('GIF search isn\'t set up',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(
              'This build has no Tenor API key. Add one at build time with '
              '--dart-define=TENOR_API_KEY=… and the GIF tab starts working.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13.5, color: AppColors.subtle(context)),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoResults extends StatelessWidget {
  final String message;
  const _NoResults({required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(message, style: TextStyle(color: AppColors.subtle(context))),
    );
  }
}
