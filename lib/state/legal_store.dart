import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../legal/legal_content.dart';
import '../relay/relay_config.dart';

/// The live Terms of Service and Privacy Policy.
///
/// The app ships with built-in documents ([termsOfService], [privacyPolicy],
/// [legalVersion]). This store lets the OWNER update them from inside the app:
/// a published document overrides the built-in one for everyone, and bumping
/// the version re-prompts every user to agree. Writes go through the owner-gated
/// `legal-set` Edge Function; reads are the public `legal_documents` row.
///
/// It degrades safely: with no server, or before the fetch lands, the built-in
/// documents show and the built-in version gates. A fetched copy is cached, so
/// the last-known documents survive an offline launch.
class LegalStore extends ChangeNotifier {
  LegalStore._();
  static final LegalStore instance = LegalStore._();

  static const _kCache = 'legal_docs_cache_v1';

  List<LegalSection>? _terms;
  List<LegalSection>? _privacy;
  int _serverVersion = 0;
  String _serverUpdated = '';

  /// The documents to show — the owner's published version if there is one,
  /// otherwise the built-in defaults.
  List<LegalSection> get terms => _terms ?? termsOfService;
  List<LegalSection> get privacy => _privacy ?? privacyPolicy;
  String get lastUpdated =>
      _serverUpdated.isNotEmpty ? _serverUpdated : legalLastUpdated;

  /// The version the acceptance gate compares against: the higher of the
  /// build's built-in [legalVersion] and whatever the owner has published, so
  /// a newer build and a newer publish both re-prompt.
  int get version => _serverVersion > legalVersion ? _serverVersion : legalVersion;

  SupabaseClient? get _client =>
      RelayConfig.isEnabled ? Supabase.instance.client : null;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kCache);
      if (raw != null && raw.isNotEmpty) {
        _applyJson(Map<String, dynamic>.from(jsonDecode(raw) as Map));
      }
    } catch (_) {}
  }

  void _applyJson(Map<String, dynamic> j) {
    List<LegalSection>? parse(dynamic v) {
      if (v is List && v.isNotEmpty) {
        return [
          for (final e in v)
            LegalSection.fromJson(Map<String, dynamic>.from(e as Map))
        ];
      }
      return null;
    }

    _terms = parse(j['terms']) ?? _terms;
    _privacy = parse(j['privacy']) ?? _privacy;
    _serverVersion = (j['version'] as num?)?.toInt() ?? _serverVersion;
    _serverUpdated =
        (j['lastUpdated'] ?? j['last_updated']) as String? ?? _serverUpdated;
    notifyListeners();
  }

  /// Fetches the current documents from the public `legal_documents` row and
  /// caches them. Best-effort — a failure leaves the last-known copy in place.
  Future<void> refresh() async {
    final client = _client;
    if (client == null) return;
    try {
      final row = await client
          .from('legal_documents')
          .select('terms, privacy, version, last_updated')
          .eq('id', 1)
          .maybeSingle();
      if (row == null) return;
      final map = <String, dynamic>{
        'terms': row['terms'],
        'privacy': row['privacy'],
        'version': row['version'],
        'lastUpdated': row['last_updated'],
      };
      _applyJson(map);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kCache, jsonEncode(map));
    } catch (_) {}
  }

  /// Publishes new documents (owner only, enforced server-side). Returns the
  /// new version on success, or null. Reflects the change locally at once.
  Future<int?> publish({
    required List<LegalSection> terms,
    required List<LegalSection> privacy,
    required String lastUpdated,
  }) async {
    final override = debugPublishOverride;
    int? version;
    if (override != null) {
      version = await override(terms, privacy, lastUpdated);
    } else {
      final client = _client;
      if (client == null) return null;
      try {
        final res = await client.functions.invoke('legal-set', body: {
          'what': 'publish',
          'terms': [for (final s in terms) s.toJson()],
          'privacy': [for (final s in privacy) s.toJson()],
          'lastUpdated': lastUpdated,
        });
        final data = res.data;
        if (data is Map && data['ok'] == true) {
          version = (data['version'] as num?)?.toInt();
        }
      } catch (_) {
        return null;
      }
    }
    if (version == null) return null;
    _terms = terms;
    _privacy = privacy;
    _serverUpdated = lastUpdated;
    _serverVersion = version;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _kCache,
          jsonEncode({
            'terms': [for (final s in terms) s.toJson()],
            'privacy': [for (final s in privacy) s.toJson()],
            'version': version,
            'lastUpdated': lastUpdated,
          }));
    } catch (_) {}
    return version;
  }

  /// Stands in for the Edge Function in tests; returns the new version.
  @visibleForTesting
  static Future<int?> Function(
    List<LegalSection> terms,
    List<LegalSection> privacy,
    String lastUpdated,
  )? debugPublishOverride;

  @visibleForTesting
  void resetForTest() {
    _terms = null;
    _privacy = null;
    _serverVersion = 0;
    _serverUpdated = '';
    debugPublishOverride = null;
  }
}
