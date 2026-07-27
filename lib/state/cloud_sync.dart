import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:pointycastle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_state.dart';
import '../crypto/e2e.dart';
import '../relay/relay_config.dart';
import '../relay/relay_service.dart';
import 'chat_store.dart';
import 'community_store.dart';
import 'feed_store.dart';
import 'follow_store.dart';
import 'saved_places_store.dart';
import 'score_store.dart';

/// End-to-end encrypted cloud sync: everything (chats, feed, follows, saved
/// places, communities and the Okay Score) is serialized, encrypted **on this
/// device** with a key derived from the user's sync passphrase, and only the
/// ciphertext is stored on the server. The server never learns who a blob
/// belongs to either — the row id
/// is an HMAC of the derived key, so it's meaningless without the
/// passphrase. Losing the passphrase means the backup is unrecoverable by
/// anyone, including us; that's the point.
class CloudSync extends ChangeNotifier {
  CloudSync._();
  static final CloudSync instance = CloudSync._();

  static const _kEnabled = 'cloud_sync_enabled';
  static const _kPass = 'cloud_sync_passphrase';
  static const table = 'sync_blobs';

  bool _enabled = false;
  String _passphrase = '';
  DateTime? lastSync;
  String? lastError;
  bool syncing = false;
  Timer? _debounce;
  bool _listening = false;

  bool get enabled => _enabled;
  bool get configured => _passphrase.length >= 6;
  String get passphrase => _passphrase;

  /// Test hook: replaces the HTTP roundtrip (upload/download) entirely.
  @visibleForTesting
  static Map<String, String>? debugServerOverride;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_kEnabled) ?? false;
      _passphrase = prefs.getString(_kPass) ?? '';
      if (_enabled && configured) _startListening();
      notifyListeners();
    } catch (_) {}
  }

  Future<void> configure({required String passphrase, required bool on}) async {
    _passphrase = passphrase.trim();
    _enabled = on && configured;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kEnabled, _enabled);
      await prefs.setString(_kPass, _passphrase);
    } catch (_) {}
    if (_enabled) {
      _startListening();
      scheduleSync();
    }
    notifyListeners();
  }

  /// Auto-sync: any change to a synced store schedules an upload.
  void _startListening() {
    if (_listening) return;
    _listening = true;
    ChatStore.instance.addListener(scheduleSync);
    FeedStore.instance.addListener(scheduleSync);
    FollowStore.instance.addListener(scheduleSync);
    SavedPlacesStore.instance.addListener(scheduleSync);
    CommunityStore.instance.addListener(scheduleSync);
    ScoreStore.instance.addListener(scheduleSync);
  }

  /// Debounced: bursts of edits collapse into one upload.
  void scheduleSync() {
    if (!_enabled || !configured) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 8), syncNow);
  }

  /// The 32-byte sync key: PBKDF2-HMAC-SHA256 over the passphrase, salted
  /// with the account digits (120k rounds), then used for AES-256-GCM via
  /// [E2eCrypto] and for the blob-id HMAC.
  static Uint8List deriveSyncKey(String passphrase, String digits) {
    final kdf = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(Pbkdf2Parameters(
          Uint8List.fromList(utf8.encode('okay-sync|$digits')), 120000, 32));
    return kdf.process(Uint8List.fromList(utf8.encode(passphrase)));
  }

  /// The server row id: an HMAC of the sync key. Unguessable without the
  /// passphrase, and reveals nothing about the account.
  static String blobIdFor(Uint8List syncKey) {
    final mac = HMac(SHA256Digest(), 64)..init(KeyParameter(syncKey));
    final out = mac.process(Uint8List.fromList(utf8.encode('blob-id')));
    return out.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  String get _digits {
    final d = RelayService.digits(AppState.profile.value.phone);
    return d.isEmpty ? 'local' : d;
  }

  /// Everything worth restoring on a new device, as one JSON document.
  Map<String, dynamic> buildPayload() => {
        'v': 1,
        'chats': ChatStore.instance.toJson(),
        'feed': FeedStore.instance.exportPosts(),
        'follows': FollowStore.instance.following.toList()..sort(),
        'places': SavedPlacesStore.instance.exportPlaces(),
        'communities': CommunityStore.instance.toJsonList(),
        'score': ScoreStore.instance.toJson(),
      };

  /// Applies a decrypted payload back onto the local stores.
  void applyPayload(Map<String, dynamic> payload) {
    final chats = payload['chats'];
    if (chats is Map<String, dynamic>) ChatStore.instance.hydrate(chats);
    final feed = payload['feed'];
    if (feed is List) FeedStore.instance.hydratePosts(feed);
    final follows = payload['follows'];
    if (follows is List) {
      FollowStore.instance.setAll(follows.whereType<String>());
    }
    final places = payload['places'];
    if (places is List) SavedPlacesStore.instance.hydratePlaces(places);
    final communities = payload['communities'];
    if (communities is List) CommunityStore.instance.hydrate(communities);
    final score = payload['score'];
    if (score is Map) {
      ScoreStore.instance.hydrate(Map<String, dynamic>.from(score));
    }
  }

  /// Pulls the server's copy back down, but only when sync is actually set
  /// up — safe to call from anywhere (pull-to-refresh does, on every screen).
  /// Never throws and never reports an error to the user: an unconfigured or
  /// offline device should just refresh nothing.
  Future<void> refreshFromServer() async {
    if (!_enabled || !configured) return;
    try {
      await restore();
    } catch (_) {}
  }

  /// Encrypts and uploads the current state. Returns null on success or a
  /// human-readable error.
  Future<String?> syncNow() async {
    if (!configured) return 'Set a sync passphrase first.';
    syncing = true;
    lastError = null;
    notifyListeners();
    try {
      final key = deriveSyncKey(_passphrase, _digits);
      final id = blobIdFor(key);
      final data = E2eCrypto.encrypt(key, jsonEncode(buildPayload()));
      final debug = debugServerOverride;
      if (debug != null) {
        debug[id] = data;
      } else {
        if (!RelayConfig.isEnabled) return _fail('No server configured.');
        final res = await http
            .post(
              Uri.parse('${RelayConfig.supabaseUrl}/rest/v1/$table'),
              headers: {
                'apikey': RelayConfig.supabaseAnonKey,
                'Authorization': 'Bearer ${RelayConfig.supabaseAnonKey}',
                'Content-Type': 'application/json',
                'Prefer': 'resolution=merge-duplicates',
              },
              body: jsonEncode([
                {'id': id, 'data': data}
              ]),
            )
            .timeout(const Duration(seconds: 15));
        if (res.statusCode == 404 || res.body.contains('PGRST205')) {
          return _fail('The server isn\'t provisioned yet — the sync table '
              'is missing. Run docs/supabase_setup.sql once in the Supabase '
              'SQL editor.');
        }
        if (res.statusCode >= 300) {
          return _fail('Upload failed (${res.statusCode}).');
        }
      }
      lastSync = DateTime.now();
      return null;
    } catch (_) {
      return _fail('Couldn\'t reach the server — check your connection.');
    } finally {
      syncing = false;
      notifyListeners();
    }
  }

  /// Downloads and decrypts the stored blob, replacing local state.
  /// Returns null on success or a human-readable error.
  Future<String?> restore() async {
    if (!configured) return 'Set a sync passphrase first.';
    syncing = true;
    lastError = null;
    notifyListeners();
    try {
      final key = deriveSyncKey(_passphrase, _digits);
      final id = blobIdFor(key);
      String? data;
      final debug = debugServerOverride;
      if (debug != null) {
        data = debug[id];
      } else {
        if (!RelayConfig.isEnabled) return _fail('No server configured.');
        final res = await http.get(
          Uri.parse('${RelayConfig.supabaseUrl}/rest/v1/$table'
              '?id=eq.$id&select=data'),
          headers: {
            'apikey': RelayConfig.supabaseAnonKey,
            'Authorization': 'Bearer ${RelayConfig.supabaseAnonKey}',
          },
        ).timeout(const Duration(seconds: 15));
        if (res.statusCode == 404 || res.body.contains('PGRST205')) {
          return _fail('The server isn\'t provisioned yet — the sync table '
              'is missing. Run docs/supabase_setup.sql once in the Supabase '
              'SQL editor.');
        }
        if (res.statusCode >= 300) {
          return _fail('Download failed (${res.statusCode}).');
        }
        final decoded = jsonDecode(res.body);
        if (decoded is List && decoded.isNotEmpty && decoded.first is Map) {
          data = (decoded.first as Map)['data'] as String?;
        }
      }
      if (data == null) return _fail('No backup found for this passphrase.');
      final plain = E2eCrypto.decrypt(key, data);
      if (plain == null) {
        return _fail('Wrong passphrase (or corrupted backup).');
      }
      final payload = jsonDecode(plain);
      if (payload is! Map<String, dynamic>) {
        return _fail('Backup is unreadable.');
      }
      applyPayload(payload);
      lastSync = DateTime.now();
      return null;
    } catch (_) {
      return _fail('Couldn\'t reach the server — check your connection.');
    } finally {
      syncing = false;
      notifyListeners();
    }
  }

  String _fail(String message) {
    lastError = message;
    return message;
  }

  @visibleForTesting
  void resetForTest() {
    _enabled = false;
    _passphrase = '';
    lastSync = null;
    lastError = null;
    _debounce?.cancel();
  }
}
