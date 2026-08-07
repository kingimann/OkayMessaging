import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../state/sticker_store.dart';
import '../theme/app_theme.dart';
import 'emoji_data.dart';

/// What the sticker sheet hands back: exactly one of the three.
class StickerChoice {
  /// An emoji to send as a sticker.
  final String? emoji;

  /// A saved photo sticker (data URI) to send again.
  final String? photoUri;

  /// The user wants to make a sticker from a new photo.
  final bool newPhoto;

  const StickerChoice.emoji(String this.emoji)
      : photoUri = null,
        newPhoto = false;
  const StickerChoice.photo(String this.photoUri)
      : emoji = null,
        newPhoto = false;
  const StickerChoice.fromNewPhoto()
      : emoji = null,
        photoUri = null,
        newPhoto = true;
}

/// The sticker picker: the user's own saved photo stickers and recents
/// first, the offered emoji grid under them, and the way to mint a new one
/// from a photo. Returns null when dismissed.
Future<StickerChoice?> showStickerSheet(BuildContext context) =>
    showModalBottomSheet<StickerChoice>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => const _StickerSheet(),
    );

class _StickerSheet extends StatefulWidget {
  const _StickerSheet();

  @override
  State<_StickerSheet> createState() => _StickerSheetState();
}

class _StickerSheetState extends State<_StickerSheet> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.6,
        child: ListenableBuilder(
          listenable: StickerStore.instance,
          builder: (context, _) {
            final store = StickerStore.instance;
            final searching = _query.trim().isNotEmpty;
            final List<String> matches =
                searching ? EmojiData.search(_query) : const <String>[];
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: TextField(
                    controller: _search,
                    onChanged: (v) => setState(() => _query = v),
                    decoration: InputDecoration(
                      hintText: 'Search emoji stickers',
                      prefixIcon: const Icon(Icons.search, size: 20),
                      suffixIcon: searching
                          ? IconButton(
                              icon: const Icon(Icons.close, size: 20),
                              onPressed: () => setState(() {
                                _search.clear();
                                _query = '';
                              }),
                            )
                          : null,
                      isDense: true,
                      filled: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    children: [
                      if (searching) ...[
                        if (matches.isEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 24),
                            child: Text('No emoji matches "${_query.trim()}".',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    color: AppColors.subtle(context))),
                          )
                        else
                          _emojiGrid(context, matches),
                      ] else ...[
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(
                              Icons.add_photo_alternate_outlined),
                          title: const Text('New sticker from a photo'),
                          subtitle: const Text(
                              'Sent small and clean, like a sticker'),
                          onTap: () => Navigator.of(context)
                              .pop(const StickerChoice.fromNewPhoto()),
                        ),
                        if (store.photos.isNotEmpty) ...[
                          _label(context, 'YOUR STICKERS'),
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: [
                              for (final uri in store.photos)
                                GestureDetector(
                                  onTap: () => Navigator.of(context)
                                      .pop(StickerChoice.photo(uri)),
                                  onLongPress: () =>
                                      _confirmRemove(context, uri),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(12),
                                    child: _photoThumb(uri),
                                  ),
                                ),
                            ],
                          ),
                        ],
                        if (store.recent.isNotEmpty) ...[
                          _label(context, 'RECENT'),
                          _emojiGrid(context, store.recent),
                        ],
                        _label(context, 'STICKERS'),
                        _emojiGrid(context, StickerStore.curated),
                        // Any emoji, not just the curated set — the "custom
                        // emoji" the search box finds, laid out to browse too.
                        _label(context, 'ALL EMOJI'),
                        _emojiGrid(context, EmojiData.all),
                      ],
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _label(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(0, 14, 0, 8),
        child: Text(text,
            style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
                color: AppColors.subtle(context))),
      );

  Widget _emojiGrid(BuildContext context, List<String> emoji) => Wrap(
        children: [
          for (final e in emoji)
            InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () =>
                  Navigator.of(context).pop(StickerChoice.emoji(e)),
              child: SizedBox(
                width: 52,
                height: 52,
                child: Center(
                  child: Text(e, style: const TextStyle(fontSize: 34)),
                ),
              ),
            ),
        ],
      );

  Widget _photoThumb(String dataUri) {
    try {
      final data = Uri.parse(dataUri).data;
      if (data != null) {
        return Image.memory(data.contentAsBytes(),
            width: 72, height: 72, fit: BoxFit.cover);
      }
    } catch (_) {}
    return Container(
      width: 72,
      height: 72,
      color: Colors.grey.shade300,
      child: const Icon(Icons.broken_image_outlined, size: 24),
    );
  }

  void _confirmRemove(BuildContext context, String uri) async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove this sticker?'),
        content:
            const Text('It only leaves your saved stickers — nothing sent '
                'is affected.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (remove == true) StickerStore.instance.removePhoto(uri);
  }
}

/// Decodes a data-URI sticker for the transcript. Shared with the bubble so
/// the sheet's thumbnail and the sent sticker can never disagree on how a
/// URI is read.
Uint8List? stickerBytes(String dataUri) {
  try {
    return Uri.parse(dataUri).data?.contentAsBytes();
  } catch (_) {
    return null;
  }
}
