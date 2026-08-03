import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stickers, the way this app can honestly have them: emoji drawn huge, and
/// the user's own photos — nothing shipped, nothing invented, and everything
/// riding the same sealed message paths words and photos already use.
///
/// The curated grid below is OFFERED, never seeded (the quick-reply rule
/// wearing another hat): a fresh account has no recents and no saved photo
/// stickers, and nothing here claims any activity that didn't happen.
class StickerStore extends ChangeNotifier {
  StickerStore._();
  static final StickerStore instance = StickerStore._();

  static const _kRecent = 'sticker_recent_v1';
  static const _kPhotos = 'sticker_photos_v1';

  /// Most-recent-first emoji the user actually sent as stickers.
  static const int maxRecent = 24;

  /// Saved photo stickers (data URIs). Capped hard: each is a real image in
  /// SharedPreferences, and a hoard nobody scrolls is just a slow launch.
  static const int maxPhotos = 12;

  /// The offered grid — sticker-worthy emoji, big and expressive. A fixed
  /// list on purpose: it renders identically on both ends because it IS the
  /// emoji, not an asset that could be missing.
  static const List<String> curated = [
    '😀', '😂', '🥹', '😍', '🥰', '😘', '😎', '🤩',
    '🥳', '😭', '😅', '😬', '🙃', '😴', '🤯', '🥶',
    '😈', '🤠', '🤡', '👻', '💀', '👽', '🤖', '🎃',
    '❤️', '🧡', '💛', '💚', '💙', '💜', '🖤', '💔',
    '💯', '🔥', '✨', '🎉', '🎊', '👍', '👎', '👏',
    '🙌', '🤝', '💪', '🙏', '✌️', '🤞', '🫶', '🫡',
    '🍕', '🍔', '🌮', '🍩', '🍦', '☕', '🧋', '🍿',
    '⚽', '🏀', '🎮', '🎲', '🎸', '🚀', '🌈', '🌸',
  ];

  List<String> _recent = [];
  List<String> _photos = [];
  SharedPreferences? _prefs;

  List<String> get recent => List.unmodifiable(_recent);
  List<String> get photos => List.unmodifiable(_photos);

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    try {
      _recent =
          (jsonDecode(_prefs!.getString(_kRecent) ?? '[]') as List)
              .cast<String>();
    } catch (_) {}
    try {
      _photos =
          (jsonDecode(_prefs!.getString(_kPhotos) ?? '[]') as List)
              .cast<String>();
    } catch (_) {}
    notifyListeners();
  }

  /// Records an emoji sticker being sent, so it floats to the front.
  void noteUsed(String emoji) {
    _recent
      ..remove(emoji)
      ..insert(0, emoji);
    if (_recent.length > maxRecent) {
      _recent = _recent.sublist(0, maxRecent);
    }
    _prefs?.setString(_kRecent, jsonEncode(_recent));
    notifyListeners();
  }

  /// Saves a photo sticker so it can be sent again without re-picking.
  /// Deduplicated by content; newest first; oldest falls off the cap.
  void savePhoto(String dataUri) {
    _photos
      ..remove(dataUri)
      ..insert(0, dataUri);
    if (_photos.length > maxPhotos) {
      _photos = _photos.sublist(0, maxPhotos);
    }
    _prefs?.setString(_kPhotos, jsonEncode(_photos));
    notifyListeners();
  }

  /// Removes a saved photo sticker (long-press in the sheet).
  void removePhoto(String dataUri) {
    if (_photos.remove(dataUri)) {
      _prefs?.setString(_kPhotos, jsonEncode(_photos));
      notifyListeners();
    }
  }

  @visibleForTesting
  void resetForTest() {
    _recent = [];
    _photos = [];
    _prefs = null;
    notifyListeners();
  }
}
