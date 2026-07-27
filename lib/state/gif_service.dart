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

/// GIF search, backed by Tenor.
///
/// The API key is supplied at build time, the same way the Supabase and Stripe
/// keys are:
///
///   flutter build web --dart-define=TENOR_API_KEY=AIza...
///
/// A Tenor key is free (Google Cloud → "Tenor API"). Without one the picker
/// says so rather than pretending to search; nothing else in the app changes,
/// and a GIF that has already been sent still plays.
class GifService {
  GifService._();
  static final GifService instance = GifService._();

  static const String apiKey =
      String.fromEnvironment('TENOR_API_KEY', defaultValue: '');

  /// Identifies this app to Tenor; required alongside the key.
  static const String _client = 'okaymessenger';

  static const String _base = 'https://tenor.googleapis.com/v2';

  bool get isConfigured => apiKey.isNotEmpty;

  /// Test hook: swaps the HTTP call for canned JSON.
  static Future<String> Function(Uri uri)? debugFetch;

  /// What's trending right now — the picker's default view.
  Future<List<GifResult>> featured({int limit = 24}) =>
      _get('$_base/featured?key=$apiKey&client_key=$_client&limit=$limit'
          '&media_filter=tinygif,gif&contentfilter=medium');

  /// GIFs matching [query]. An empty query falls back to [featured].
  Future<List<GifResult>> search(String query, {int limit = 24}) {
    final q = query.trim();
    if (q.isEmpty) return featured(limit: limit);
    return _get('$_base/search?key=$apiKey&client_key=$_client&limit=$limit'
        '&q=${Uri.encodeQueryComponent(q)}'
        '&media_filter=tinygif,gif&contentfilter=medium');
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

  /// Maps a Tenor response body to [GifResult]s. Pure, so the shape of the
  /// response is unit-tested without a network call.
  static List<GifResult> parseResults(String body) {
    final out = <GifResult>[];
    final decoded = jsonDecode(body);
    if (decoded is! Map) return out;
    final results = decoded['results'];
    if (results is! List) return out;
    for (final raw in results) {
      if (raw is! Map) continue;
      final formats = raw['media_formats'];
      if (formats is! Map) continue;
      final full = _format(formats, 'gif') ?? _format(formats, 'tinygif');
      final preview = _format(formats, 'tinygif') ?? full;
      if (full == null || preview == null) continue;
      final dims = (formats['tinygif'] ?? formats['gif']) as Map?;
      final size = dims?['dims'];
      var ratio = 1.0;
      if (size is List && size.length == 2) {
        final w = (size[0] as num).toDouble();
        final h = (size[1] as num).toDouble();
        if (w > 0 && h > 0) ratio = w / h;
      }
      out.add(GifResult(
        id: (raw['id'] ?? full).toString(),
        url: full,
        previewUrl: preview,
        description: (raw['content_description'] ?? '').toString(),
        aspectRatio: ratio,
      ));
    }
    return out;
  }

  static String? _format(Map formats, String name) {
    final entry = formats[name];
    if (entry is! Map) return null;
    final url = entry['url'];
    return url is String && url.isNotEmpty ? url : null;
  }
}
