import 'dart:convert';

import 'package:http/http.dart' as http;

/// A GIF from the picker: the animated file plus a still preview for the grid.
class GifResult {
  final String id;
  final String url;
  final String previewUrl;
  final String description;
  final double aspectRatio;

  const GifResult({
    required this.id,
    required this.url,
    required this.previewUrl,
    this.description = '',
    this.aspectRatio = 1,
  });
}

/// GIF search, backed by KLIPY.
///
/// It used to be Tenor. Google shut that API down on 30 June 2026 — new keys
/// stopped being issued in January and existing ones started returning errors
/// on the day — so every GIF picker built on it, this one included, went dark.
/// KLIPY is the migration Bluesky and WhatsApp took: it is run by people who
/// built Tenor, it keeps a free tier (GIPHY dropped theirs), and it serves a
/// deliberately Tenor-shaped API so the move is a base URL and a key.
///
/// The key is supplied at build time, the same way the Supabase and Stripe
/// keys are:
///
///   flutter build web --dart-define=KLIPY_API_KEY=...
///
/// Without one the picker says so rather than pretending to search; nothing
/// else in the app changes, and a GIF that has already been sent still plays
/// — those are ordinary image URLs and none of them point at Tenor.
class GifService {
  GifService._();
  static final GifService instance = GifService._();

  static const String apiKey =
      String.fromEnvironment('KLIPY_API_KEY', defaultValue: '');

  /// Identifies this app to the provider; carried over from Tenor, which
  /// required it alongside the key. Harmless where it is ignored.
  static const String _client = 'okaymessenger';

  static const String _base = 'https://api.klipy.com/v2';

  bool get isConfigured => apiKey.isNotEmpty;

  /// Test hook: swaps the HTTP call for canned JSON.
  static Future<String> Function(Uri uri)? debugFetch;

  /// The formats worth asking for, smallest to largest. KLIPY serves the two
  /// Tenor had plus three more; asking for all of them costs nothing and gives
  /// [parseResults] something to fall back through when a result is missing
  /// the size it would have preferred.
  static const String _formats = 'nanogif,tinygif,mediumgif,gif,preview';

  /// What's trending right now — the picker's default view.
  Future<List<GifResult>> featured({int limit = 24}) =>
      _get('$_base/featured?key=$apiKey&client_key=$_client&limit=$limit'
          '&media_filter=$_formats&contentfilter=medium');

  /// GIFs matching [query]. An empty query falls back to [featured].
  Future<List<GifResult>> search(String query, {int limit = 24}) {
    final q = query.trim();
    if (q.isEmpty) return featured(limit: limit);
    return _get('$_base/search?key=$apiKey&client_key=$_client&limit=$limit'
        '&q=${Uri.encodeQueryComponent(q)}'
        '&media_filter=$_formats&contentfilter=medium');
  }

  Future<List<GifResult>> _get(String url) async {
    if (!isConfigured) return const [];
    try {
      final uri = Uri.parse(url);
      final body = debugFetch != null
          ? await debugFetch!(uri)
          : (await http.get(uri).timeout(const Duration(seconds: 12))).body;
      return parseResults(body);
    } catch (_) {
      return const [];
    }
  }

  /// Maps a provider response to [GifResult]s. Pure, so the shape of the
  /// response is unit-tested without a network call.
  ///
  /// Reads **both** shapes on purpose. KLIPY's compatibility endpoint answers
  /// in Tenor's (`results` / `media_formats`), which is the point of it, and
  /// its native API answers in its own (`data.data` / `files`). The two are
  /// documented inconsistently and neither can be checked from here without a
  /// key, so this accepts either rather than betting the GIF tab on which one
  /// arrives — the failure mode of guessing wrong is a grid that is silently
  /// always empty.
  static List<GifResult> parseResults(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map) return const [];
    final items = _items(decoded);
    final out = <GifResult>[];
    for (final raw in items) {
      if (raw is! Map) continue;
      final formats = raw['media_formats'] ?? raw['files'];
      if (formats is! Map) continue;
      // Biggest first for the file that gets sent, smallest first for the
      // thumbnail the grid draws dozens of.
      final full = _firstOf(formats, const ['gif', 'mediumgif', 'tinygif',
        'nanogif', 'preview']);
      final preview = _firstOf(formats, const ['tinygif', 'nanogif', 'preview',
        'mediumgif', 'gif']);
      if (full == null || preview == null) continue;
      out.add(GifResult(
        id: (raw['id'] ?? raw['slug'] ?? full).toString(),
        url: full,
        previewUrl: preview,
        description:
            (raw['content_description'] ?? raw['title'] ?? '').toString(),
        aspectRatio: _ratio(formats),
      ));
    }
    return out;
  }

  /// The list of results, wherever this provider keeps it.
  static List<dynamic> _items(Map decoded) {
    final tenorish = decoded['results'];
    if (tenorish is List) return tenorish;
    final data = decoded['data'];
    if (data is List) return data;
    if (data is Map && data['data'] is List) return data['data'] as List;
    return const [];
  }

  /// Width ÷ height from whichever format carries usable dimensions. Falls
  /// back to square, which is what the grid assumed before any of this.
  static double _ratio(Map formats) {
    for (final name in const ['tinygif', 'nanogif', 'gif', 'mediumgif',
      'preview']) {
      final entry = formats[name];
      if (entry is! Map) continue;
      final dims = entry['dims'];
      double? w, h;
      if (dims is List && dims.length == 2) {
        w = (dims[0] as num?)?.toDouble();
        h = (dims[1] as num?)?.toDouble();
      } else {
        w = (entry['width'] as num?)?.toDouble();
        h = (entry['height'] as num?)?.toDouble();
      }
      if (w != null && h != null && w > 0 && h > 0) return w / h;
    }
    return 1;
  }

  /// The first of [names] that carries a usable URL.
  static String? _firstOf(Map formats, List<String> names) {
    for (final name in names) {
      final url = _format(formats, name);
      if (url != null) return url;
    }
    return null;
  }

  static String? _format(Map formats, String name) {
    final entry = formats[name];
    if (entry is! Map) return null;
    // Tenor puts the address at `url`; KLIPY's native shape has been seen
    // using `src` for the same thing.
    final url = entry['url'] ?? entry['src'];
    return url is String && url.isNotEmpty ? url : null;
  }
}
