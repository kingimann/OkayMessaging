import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'relay_config.dart';

/// Fetches TURN relay credentials from the `turn-credentials` Edge Function
/// at call time, so the relay that actually decides cellular-to-cellular
/// calls is one the project controls — the free public relay baked into
/// the static config is dead from real networks, and the call self-test
/// proved it (STUN green, relay red).
///
/// Fail-open by design at every step: a short timeout, a cache so one
/// answer serves the whole call burst, and an empty list on any failure —
/// this fetch may only ever ADD ice servers, never delay or break a call.
/// Plain HTTP with the anon key rather than the Supabase client, because
/// numberless accounts have no session and their calls need the relay too.
class TurnService {
  TurnService._();

  static List<Map<String, dynamic>>? _cached;
  static DateTime? _fetchedAt;
  static Duration _ttl = const Duration(minutes: 30);

  /// Test hook: injected response body, as the function would answer.
  static String? debugResponse;

  /// Extra ICE servers to merge into the call config — possibly empty,
  /// never a thrown error, never slower than ~4 seconds.
  static Future<List<Map<String, dynamic>>> iceServers() async {
    if (!RelayConfig.isEnabled && debugResponse == null) return const [];
    final cached = _cached;
    final at = _fetchedAt;
    if (cached != null && at != null && DateTime.now().difference(at) < _ttl) {
      return cached;
    }
    try {
      final String body;
      if (debugResponse != null) {
        body = debugResponse!;
      } else {
        final res = await http
            .post(
              Uri.parse(
                  '${RelayConfig.supabaseUrl}/functions/v1/turn-credentials'),
              headers: {
                'apikey': RelayConfig.supabaseAnonKey,
                'Authorization': 'Bearer ${RelayConfig.supabaseAnonKey}',
                'Content-Type': 'application/json',
              },
              body: '{}',
            )
            .timeout(const Duration(seconds: 4));
        if (res.statusCode >= 300) return _cached ?? const [];
        body = res.body;
      }
      final parsed = parseIceServers(body);
      _cached = parsed.servers;
      _fetchedAt = DateTime.now();
      if (parsed.ttlSeconds > 0) {
        // Refresh comfortably before the credentials expire.
        _ttl = Duration(seconds: (parsed.ttlSeconds * 0.8).round());
      }
      return parsed.servers;
    } catch (_) {
      return _cached ?? const [];
    }
  }

  /// Parses the function's answer into ice-server maps. Pure, so a test
  /// can pin exactly what shapes are accepted — a malformed answer yields
  /// an empty list, never a throw.
  static ({List<Map<String, dynamic>> servers, int ttlSeconds}) parseIceServers(
      String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return (servers: const [], ttlSeconds: 0);
      final raw = decoded['iceServers'];
      if (raw is! List) return (servers: const [], ttlSeconds: 0);
      final servers = <Map<String, dynamic>>[
        for (final s in raw)
          if (s is Map && s['urls'] != null)
            {
              'urls': s['urls'],
              if (s['username'] != null) 'username': s['username'],
              if (s['credential'] != null) 'credential': s['credential'],
            }
      ];
      return (
        servers: servers,
        ttlSeconds: (decoded['ttlSeconds'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return (servers: const [], ttlSeconds: 0);
    }
  }

  /// Drops the cache so the next call re-asks (used by the self-test's
  /// refresh, where "run it again" must mean AGAIN).
  static void invalidate() {
    _cached = null;
    _fetchedAt = null;
  }
}
