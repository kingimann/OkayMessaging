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
import 'account_email.dart';
import 'chat_store.dart';
import 'community_store.dart';
import 'feed_store.dart';
import 'follow_store.dart';
import 'saved_places_store.dart';
import 'score_store.dart';

/// Isolate tasks: PBKDF2 is ~120k HMAC rounds and AES chews through the
/// whole payload — on the main isolate either one freezes the UI (pull-to-
/// refresh visibly hung the app), so they run behind [compute].
Uint8List _deriveKeyTask(({String pass, String digits}) args) =>
    CloudSync.deriveSyncKey(args.pass, args.digits);

String _encryptTask(({Uint8List key, String plain}) args) =>
    E2eCrypto.encrypt(args.key, args.plain);

String? _decryptTask(({Uint8List key, String blob}) args) =>
    E2eCrypto.decrypt(args.key, args.blob);

/// End-to-end encrypted cloud sync. Two modes:
///
/// **Automatic (the default)** — on for everyone with no setup. Servers,
/// feed, follows, places, score and email are encrypted on-device with a key
/// derived from the account's phone number and uploaded. Reinstalling and
/// signing in with the same number brings them back without the user doing
/// anything. Chats are deliberately NOT in the automatic backup: a
/// phone-derived key must never protect message content, since the phone
/// number isn't a secret.
///
/// **Passphrase** — the user sets a sync passphrase in Settings; the key is
/// derived from it instead, and chats are included. Losing the passphrase
/// means that backup is unrecoverable by anyone, including us.
///
/// Either way the server stores only ciphertext, and the row id is an HMAC
/// of the key, so blobs reveal nothing about the account.
class CloudSync extends ChangeNotifier {
  CloudSync._();
  static final CloudSync instance = CloudSync._();

  static const _kEnabled = 'cloud_sync_enabled';
  static const _kPass = 'cloud_sync_passphrase';
  static const table = 'sync_blobs';

  /// The fixed "passphrase" of automatic mode. Secrecy comes only from the
  /// per-account salt (the phone digits), which is why chats stay out.
  static const autoPassphrase = 'okay-auto-v1';

  bool _enabled = true;
  String _passphrase = '';
  DateTime? lastSync;
  String? lastError;
  bool syncing = false;
  Timer? _debounce;
  bool _listening = false;

  bool get enabled => _enabled;

  /// True while no custom passphrase is set — syncing rides the phone-derived
  /// key and excludes chats.
  bool get autoMode => _passphrase.length < 6;

  /// Ready to sync: a custom passphrase, or (auto mode) a signed-in account
  /// whose digits can salt the key.
  bool get configured => !autoMode || _digits != 'local';
  String get passphrase => _passphrase;

  String get _effectivePassphrase => autoMode ? autoPassphrase : _passphrase;

  /// Test hook: replaces the HTTP roundtrip (upload/download) entirely.
  @visibleForTesting
  static Map<String, String>? debugServerOverride;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Sync is on unless the user explicitly turned it off.
      _enabled = prefs.getBool(_kEnabled) ?? true;
      _passphrase = prefs.getString(_kPass) ?? '';
      if (_enabled) {
        _startListening();
        // Boot runs before sign-in state settles, so give the profile a
        // moment, then pull an existing backup down (fresh installs only —
        // a device with local servers keeps them and uploads instead).
        Timer(const Duration(seconds: 4), autoBootstrap);
      }
      notifyListeners();
    } catch (_) {}
  }

  /// The account digits the last bootstrap ran for, so signing in (which can
  /// happen well after boot) triggers exactly one more.
  String _bootstrappedFor = '';

  /// First-run auto sync: restore when this device has nothing yet,
  /// otherwise push the local state up. Never surfaces errors — automatic
  /// mode has no UI to be noisy in.
  Future<void> autoBootstrap() async {
    if (!_enabled || !configured) return;
    final digits = _digits;
    if (digits == _bootstrappedFor) return;
    _bootstrappedFor = digits;
    try {
      final empty = CommunityStore.instance.communities.isEmpty &&
          FeedStore.instance.exportPosts().isEmpty;
      if (empty) {
        await restore();
        // "No backup yet" isn't an error when nobody asked for a restore.
        lastError = null;
        notifyListeners();
      } else {
        await syncNow();
      }
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

  /// Auto-sync: any change to a synced store schedules an upload, and a
  /// sign-in (the profile appearing) triggers the once-per-account bootstrap.
  void _startListening() {
    if (_listening) return;
    _listening = true;
    ChatStore.instance.addListener(scheduleSync);
    FeedStore.instance.addListener(scheduleSync);
    FollowStore.instance.addListener(scheduleSync);
    SavedPlacesStore.instance.addListener(scheduleSync);
    CommunityStore.instance.addListener(scheduleSync);
    ScoreStore.instance.addListener(scheduleSync);
    AppState.profile.addListener(autoBootstrap);
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

  // The derived key never changes for a given passphrase + account, so pay
  // the PBKDF2 cost once per session, off the main isolate.
  Uint8List? _keyCache;
  String _keyCacheFor = '';

  Future<Uint8List> _syncKey() async {
    final pass = _effectivePassphrase;
    final digits = _digits;
    final tag = '$pass|$digits';
    final cached = _keyCache;
    if (cached != null && _keyCacheFor == tag) return cached;
    final key = await compute(_deriveKeyTask, (pass: pass, digits: digits));
    _keyCache = key;
    _keyCacheFor = tag;
    return key;
  }

  /// Everything worth restoring on a new device, as one JSON document.
  /// Chats ride along only under a user-set passphrase — never under the
  /// automatic phone-derived key.
  Map<String, dynamic> buildPayload() => {
        'v': 1,
        if (!autoMode) 'chats': ChatStore.instance.toJson(),
        'feed': FeedStore.instance.exportPosts(),
        'follows': FollowStore.instance.following.toList()..sort(),
        'places': SavedPlacesStore.instance.exportPlaces(),
        'communities': CommunityStore.instance.toJsonList(),
        'score': ScoreStore.instance.toJson(),
        'accountEmail': AccountEmail.instance.toJson(),
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
    final accountEmail = payload['accountEmail'];
    if (accountEmail is Map) {
      AccountEmail.instance.hydrate(Map<String, dynamic>.from(accountEmail));
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
    if (!configured) return 'Sign in (or set a sync passphrase) first.';
    syncing = true;
    lastError = null;
    notifyListeners();
    try {
      final key = await _syncKey();
      final id = blobIdFor(key);
      final data = await compute(
          _encryptTask, (key: key, plain: jsonEncode(buildPayload())));
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
    if (!configured) return 'Sign in (or set a sync passphrase) first.';
    syncing = true;
    lastError = null;
    notifyListeners();
    try {
      final key = await _syncKey();
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
      final plain = await compute(_decryptTask, (key: key, blob: data));
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
    _bootstrappedFor = '';
    _keyCache = null;
    _keyCacheFor = '';
    lastSync = null;
    lastError = null;
    _debounce?.cancel();
  }
}
