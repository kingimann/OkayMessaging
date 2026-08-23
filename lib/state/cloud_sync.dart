import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:pointycastle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_state.dart';
import '../crypto/e2e.dart';
import '../crypto/identity_recovery.dart';
import '../crypto/key_exchange.dart';
import '../relay/relay_config.dart';
import '../relay/relay_service.dart';
import 'account_email.dart';
import 'account_wipe.dart';
import 'backup_prefs.dart';
import 'chat_store.dart';
import 'community_store.dart';
import 'feed_store.dart';
import 'follow_store.dart';
import 'saved_places_store.dart';
import 'score_store.dart';
import 'contacts_store.dart';
import 'notes_store.dart';
import 'storage_store.dart';

/// Isolate tasks: PBKDF2 is ~120k HMAC rounds and AES chews through the
/// whole payload — on the main isolate either one freezes the UI (pull-to-
/// refresh visibly hung the app), so they run behind [compute].
Uint8List _deriveKeyTask(({String pass, String digits}) args) =>
    CloudSync.deriveSyncKey(args.pass, args.digits);

String _encryptTask(({Uint8List key, String plain}) args) =>
    E2eCrypto.encrypt(args.key, args.plain);

String? _decryptTask(({Uint8List key, String blob}) args) =>
    E2eCrypto.decrypt(args.key, args.blob);

/// End-to-end encrypted cloud sync, in two independent halves.
///
/// **Communal data — free.** Servers, feed posts, follows, saved places, score
/// and email sync automatically for everyone, at no charge and against no
/// quota. They ride the account's phone-derived key so reinstalling and
/// signing in with the same number restores them. This is the "in general for
/// everyone" data — nobody's personal storage.
///
/// **Chats — paid, opt-in, personal.** Message history is the only thing that
/// counts as a user's personal storage. It is backed up here only if the user
/// chooses to, encrypted under a user-set passphrase (never the weak
/// phone-derived key), and its size counts against the [StorageStore] tier
/// quota. The alternative is a local backup to iCloud / app storage.
///
/// The server stores only ciphertext, and each row id is an HMAC of the key,
/// so blobs reveal nothing about the account. The chat blob uses a distinct id
/// so it never collides with the communal one.
class CloudSync extends ChangeNotifier {
  CloudSync._();
  static final CloudSync instance = CloudSync._();

  static const _kEnabled = 'cloud_sync_enabled';
  static const _kPass = 'cloud_sync_passphrase';
  static const _kPinChats = 'cloud_sync_pin_chats_v1';
  static const _kAsked = 'cloud_sync_asked_v1';
  static const _kSyncedAt = 'cloud_sync_synced_at_v1';
  static const table = 'sync_blobs';

  /// The fixed "passphrase" of automatic mode. Secrecy comes only from the
  /// per-account salt (the phone digits), which is why chats stay out.
  static const autoPassphrase = 'okay-auto-v1';

  bool _enabled = true;
  String _passphrase = '';

  /// Whether chats are sealed under the RECOVERY PIN route rather than a
  /// typed passphrase. See [useRecoveryPin] for what that actually means —
  /// the PIN is not the key.
  bool _pinChats = false;
  DateTime? lastSync;
  String? lastError;
  bool syncing = false;
  Timer? _debounce;
  bool _listening = false;

  bool get enabled => _enabled;

  /// True while no custom passphrase is set — syncing rides the phone-derived
  /// key and excludes chats.
  bool get autoMode => _passphrase.length < 6;

  /// Ready to sync the communal data: a custom passphrase, or (auto mode) a
  /// signed-in account whose digits can salt the key.
  bool get configured => !autoMode || _digits != 'local';
  String get passphrase => _passphrase;

  /// Chats can be backed up under a real user passphrase, or under the
  /// recovery-PIN route — never the phone-derived key, which isn't a secret.
  bool get chatBackupReady => !autoMode || _pinChats;

  /// Whether chats ride the recovery PIN rather than a typed passphrase.
  bool get pinChats => _pinChats;

  /// **Seal chats with the recovery PIN, which is not the same as sealing
  /// them WITH a PIN — and the difference is the whole feature.**
  ///
  /// A PIN is 4–6 digits: ten thousand to a million guesses. Deriving a
  /// backup key straight from one would be indefensible here, because the
  /// chat bucket's own access model is that the object NAME is the
  /// capability — and its read policy is a blanket SELECT, which is also
  /// what a LIST is, so the names are enumerable rather than unguessable.
  /// Anybody holding the publishable key can pull the blob down and grind
  /// it offline at their leisure. Against a 6-digit PIN, PBKDF2 at 120k
  /// rounds is a speed bump measured in hours.
  ///
  /// So the PIN is NOT the key. The key is derived from this device's
  /// **identity private key** — 256 bits from the OS CSPRNG, with nothing
  /// to grind. The PIN's only job is the one it already does: opening the
  /// sealed identity blob in `identity_backups`, which unlike the chat
  /// bucket is genuinely bound to its own account's session (`grant … to
  /// authenticated`, RLS scoped to the row's own number). Grinding the PIN
  /// therefore needs that account's session first, and a PIN with a session
  /// already in hand is not what anybody is attacking.
  ///
  /// Which makes this route **stronger than the typed passphrase it sits
  /// beside**, not a convenience traded against safety: a six-character
  /// human-chosen passphrase on an enumerable blob is the weaker of the two.
  ///
  /// And it needs nothing new to remember. The recovery PIN is already set
  /// before the first message can send, and entering it on a new device
  /// already restores the identity key — so the chat backup opens as a side
  /// effect of a step that was happening anyway. That is what "sync chat
  /// with a PIN" has to mean to be worth having.
  ///
  /// Returns false when there is no identity to derive from, or no recovery
  /// backup to get it back with — turning this on without one would seal
  /// chats to a key that dies with the phone, which is worse than not
  /// backing them up at all.
  Future<bool> useRecoveryPin({required bool on}) async {
    if (on) {
      if (!IdentityRecovery.ready.value) return false;
      final kx = SecureKeyExchange.instance;
      if (!kx.isReady) await kx.load();
      if (!kx.isReady) return false;
    }
    _pinChats = on;
    _keyCache = null;
    _chatKeyCache = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kPinChats, on);
    } catch (_) {}
    notifyListeners();
    return true;
  }

  /// Whether this device has already put the backup-passphrase question to
  /// the user, whatever they answered.
  ///
  /// A prompt that returns every launch is one people learn to dismiss
  /// without reading, which is worse than not asking: the question is about
  /// losing conversations and it has to be read once, properly. Settings is
  /// the way in afterwards either way.
  bool _asked = false;
  bool get askedAboutChatBackup => _asked;

  /// Records that the question was put, so it is not asked again.
  Future<void> noteAskedAboutChatBackup() async {
    if (_asked) return;
    _asked = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kAsked, true);
    } catch (_) {}
    notifyListeners();
  }

  /// Whether it is worth asking at all.
  ///
  /// NOT for an account with nothing to lose. A brand-new sign-in has an
  /// empty chat list, and asking somebody to invent and remember a
  /// passphrase to protect nothing is how the question gets dismissed
  /// unread — the exact reason nobody has one today. [chatCount] is passed
  /// in rather than read here so this stays pure and testable.
  bool chatBackupWorthAsking(int chatCount) =>
      !_asked && !chatBackupReady && chatCount >= chatsBeforeAsking;

  /// How many real conversations make the question worth putting. Two rather
  /// than one: the first chat is often a test message to yourself or a
  /// single hello, and neither is what somebody would be sorry to lose.
  static const int chatsBeforeAsking = 2;

  /// Everything lined up for a background (communal) upload. Free — no quota.
  bool get canSync => _enabled && configured;

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
      _pinChats = prefs.getBool(_kPinChats) ?? false;
      _asked = prefs.getBool(_kAsked) ?? false;
      _syncedAt = DateTime.tryParse(prefs.getString(_kSyncedAt) ?? '');
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
    FeedStore.instance.addListener(scheduleSync);
    FollowStore.instance.addListener(scheduleSync);
    SavedPlacesStore.instance.addListener(scheduleSync);
    ContactsStore.instance.addListener(scheduleSync);
    CommunityStore.instance.addListener(scheduleSync);
    ScoreStore.instance.addListener(scheduleSync);
    AppState.profile.addListener(autoBootstrap);
  }

  /// Debounced: bursts of edits to communal data collapse into one free
  /// upload. Chats are never auto-scheduled — they back up only on request.
  /// A no-op when the user has turned automatic backup off — then nothing
  /// uploads until they tap "Back up now".
  void scheduleSync() {
    if (!canSync || !BackupPrefs.instance.autoBackup) return;
    // Not before the server has been read once this run — see [_seenServer].
    // Only the AUTOMATIC path waits; syncNow() itself does not, so "Back up
    // now" always tries.
    if (!_seenServer) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 8), syncNow);
  }

  /// The periodic backstop for automatic backup: on app foreground/launch,
  /// if auto-backup is on and the chosen interval (daily/weekly) has elapsed
  /// since the last backup, upload now. Catches the case where the app is
  /// opened, nothing is edited, but time has passed. Silent — like the
  /// bootstrap, an automatic backup never surfaces an error.
  Future<void> maybeAutoBackup() async {
    if (!canSync || !BackupPrefs.instance.dueSince(lastSync)) return;
    await syncNow();
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

  /// The 32-byte CHAT key when chats ride the recovery PIN: derived from the
  /// identity private key rather than from anything anybody types.
  ///
  /// **HMAC, not PBKDF2, and that is not a shortcut.** Stretching exists to
  /// make each guess expensive, and there is nothing here to guess: the
  /// input is 256 bits straight from the OS CSPRNG. 120k rounds over it
  /// would cost a second of somebody's life per unlock and buy exactly
  /// nothing. (The passphrase path keeps its stretch, because there a human
  /// chose the input.)
  ///
  /// Domain-separated from every other use of the identity key, and salted
  /// per account, so this key cannot stand in for any other.
  static Uint8List deriveChatKeyFromIdentity(String privateHex, String digits) {
    final mac = HMac(SHA256Digest(), 64)
      ..init(KeyParameter(Uint8List.fromList(utf8.encode(privateHex))));
    return Uint8List.fromList(
        mac.process(Uint8List.fromList(utf8.encode('okay-chat-key|$digits'))));
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
  Uint8List? _chatKeyCache;

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

  /// The key CHAT backups are sealed with.
  ///
  /// Deliberately separate from [_syncKey]: the communal blob is small,
  /// free and phone-derived by design, while chats are the thing that must
  /// never be readable by the server. In passphrase mode the two are the
  /// SAME key, unchanged — an existing backup has to go on opening — and
  /// only the PIN route derives its own.
  Future<Uint8List> _chatKey() async {
    if (!_pinChats) return _syncKey();
    final cached = _chatKeyCache;
    if (cached != null) return cached;
    final kx = SecureKeyExchange.instance;
    if (!kx.isReady) await kx.load();
    final key = deriveChatKeyFromIdentity(kx.exportPrivate(), _digits);
    _chatKeyCache = key;
    return key;
  }

  /// Everything worth restoring on a new device, as one JSON document.
  /// Chats are deliberately excluded — message content never leaves the
  /// device, regardless of key mode or subscription.
  Map<String, dynamic> buildPayload() {
    final inc = BackupPrefs.instance.includes;
    return {
      'v': 1,
      if (inc('feed')) 'feed': FeedStore.instance.exportPosts(),
      if (inc('follows'))
        'follows': FollowStore.instance.following.toList()..sort(),
      if (inc('places')) 'places': SavedPlacesStore.instance.exportPlaces(),
      if (inc('communities'))
        'communities': CommunityStore.instance.toJsonList(),
      if (inc('score')) 'score': ScoreStore.instance.toJson(),
      // Email is always carried — it's the recovery anchor, not a data
      // category, and it's tiny.
      'accountEmail': AccountEmail.instance.toJson(),
      if (inc('notes')) 'notes': NotesStore.instance.exportNotes(),
      if (inc('contacts')) 'contacts': ContactsStore.instance.exportContacts(),
    };
  }

  /// [buildPayload] plus this account's settings slice.
  ///
  /// Separate because the slice has to be read off disk and [buildPayload] is
  /// synchronous and called from tests and the UI. The upload path uses this
  /// one, so what actually goes to the server carries everything.
  Future<Map<String, dynamic>> buildFullPayload() async {
    final payload = buildPayload();
    // When this document was written. It rides INSIDE the ciphertext, so the
    // server never sees it and cannot forge it — it is the author's own
    // stamp, and it is the whole basis of the pull below deciding whether
    // the server's copy is newer than what this device already has.
    payload['at'] = DateTime.now().toUtc().toIso8601String();
    if (BackupPrefs.instance.includes('settings')) {
      try {
        payload['settings'] = await AccountWipe.exportSettings();
      } catch (_) {
        // A slice that cannot be read must not cost the rest of the backup.
      }
    }
    return payload;
  }

  /// Applies a decrypted payload back onto the local stores.
  void applyPayload(Map<String, dynamic> payload) {
    final chats = payload['chats'];
    if (chats is Map<String, dynamic>) ChatStore.instance.hydrate(chats);
    final feed = payload['feed'];
    if (feed is List) FeedStore.instance.hydratePosts(feed);
    final follows = payload['follows'];
    if (follows is List) {
      FollowStore.instance.mergeAll(follows.whereType<String>());
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
    final notes = payload['notes'];
    if (notes is List) NotesStore.instance.hydrateNotes(notes);
    final contacts = payload['contacts'];
    if (contacts is List) ContactsStore.instance.hydrateContacts(contacts);
  }

  /// [applyPayload] with the settings slice, in the one order that works.
  ///
  /// **The slice goes FIRST and [applyPayload] second, and that is
  /// load-bearing** — the same lesson `AccountWipe._switchOwner` records for
  /// an account switch. Restoring the slice ends by rebuilding every
  /// singleton FROM DISK, so anything hydrated into memory before it would be
  /// read straight back over. Writing disk first and hydrating after leaves
  /// the payload's own copies of servers, notes, posts and contacts as the
  /// last word, which is what they are.
  Future<void> applyFullPayload(Map<String, dynamic> payload) async {
    final settings = payload['settings'];
    if (settings is Map) {
      try {
        await AccountWipe.importSettings(Map<String, dynamic>.from(settings));
      } catch (_) {
        // A slice that will not apply must not cost the rest of the restore.
      }
    }
    applyPayload(payload);
  }

  /// Pulls the server's copy back down, but only when sync is actually set
  /// up — safe to call from anywhere (pull-to-refresh does, on every screen).
  /// Never throws and never reports an error to the user: an unconfigured or
  /// offline device should just refresh nothing.
  Future<void> refreshFromServer() async {
    if (!_enabled || !configured) return;
    try {
      // Local edits still waiting on the upload debounce are NEWER than the
      // blob — pulling now would resurrect what was just changed (a deleted
      // feed post, famously). Flush the upload instead; the next refresh
      // pulls a blob that already includes it.
      if (_debounce?.isActive ?? false) {
        _debounce!.cancel();
        await syncNow();
        return;
      }
      await restore();
    } catch (_) {}
  }

  /// Uploads [data] under [id]. Returns null on success or an error message.
  Future<String?> _put(String id, String data) async {
    final debug = debugServerOverride;
    if (debug != null) {
      debug[id] = data;
      return null;
    }
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
      return _fail('The server isn\'t provisioned yet — the sync table is '
          'missing. Run docs/supabase_setup.sql once in the Supabase SQL '
          'editor.');
    }
    if (res.statusCode >= 300) return _fail('Upload failed (${res.statusCode}).');
    return null;
  }

  /// Downloads the ciphertext stored under [id], or null if none. Throws on a
  /// transport error so callers can translate it.
  Future<String?> _get(String id) async {
    final debug = debugServerOverride;
    if (debug != null) return debug[id];
    if (!RelayConfig.isEnabled) return null;
    final res = await http.get(
      Uri.parse('${RelayConfig.supabaseUrl}/rest/v1/$table'
          '?id=eq.$id&select=data'),
      headers: {
        'apikey': RelayConfig.supabaseAnonKey,
        'Authorization': 'Bearer ${RelayConfig.supabaseAnonKey}',
      },
    ).timeout(const Duration(seconds: 15));
    if (res.statusCode >= 300) return null;
    final decoded = jsonDecode(res.body);
    if (decoded is List && decoded.isNotEmpty && decoded.first is Map) {
      return (decoded.first as Map)['data'] as String?;
    }
    return null;
  }

  // --- Object storage (Supabase Storage buckets) -------------------------
  //
  // Chat backups are the only large, *paid* thing stored, so they live in a
  // Storage bucket rather than a Postgres table. Buckets bill at $0.0213/GB
  // against database disk at $0.125/GB — roughly 6× cheaper, and the
  // difference is what makes selling storage profitable at all. The small
  // communal blob stays in the table, where its size is irrelevant.

  /// Bucket holding the sealed chat backups.
  static const chatBucket = 'chat-backups';

  /// Uploads [data] to the chat bucket at [path] (upserting). Returns null on
  /// success or a human-readable error.
  Future<String?> _putObject(String path, String data) async {
    final debug = debugServerOverride;
    if (debug != null) {
      debug[path] = data;
      return null;
    }
    if (!RelayConfig.isEnabled) return _fail('No server configured.');
    final res = await http
        .post(
          Uri.parse(
              '${RelayConfig.supabaseUrl}/storage/v1/object/$chatBucket/$path'),
          headers: {
            'apikey': RelayConfig.supabaseAnonKey,
            'Authorization': 'Bearer ${RelayConfig.supabaseAnonKey}',
            'Content-Type': 'text/plain',
            'x-upsert': 'true',
          },
          body: data,
        )
        .timeout(const Duration(seconds: 30));
    if (res.statusCode == 404 && res.body.contains('Bucket not found')) {
      return _fail('Chat storage isn\'t provisioned yet — run '
          'docs/chat_backup_bucket.sql once in the Supabase SQL editor.');
    }
    if (res.statusCode >= 300) {
      return _fail('Upload failed (${res.statusCode}).');
    }
    return null;
  }

  /// Downloads the object at [path] from the chat bucket, or null if absent.
  Future<String?> _getObject(String path) async {
    final debug = debugServerOverride;
    if (debug != null) return debug[path];
    if (!RelayConfig.isEnabled) return null;
    final res = await http.get(
      Uri.parse(
          '${RelayConfig.supabaseUrl}/storage/v1/object/$chatBucket/$path'),
      headers: {
        'apikey': RelayConfig.supabaseAnonKey,
        'Authorization': 'Bearer ${RelayConfig.supabaseAnonKey}',
      },
    ).timeout(const Duration(seconds: 30));
    if (res.statusCode >= 300) return null;
    return res.body.isEmpty ? null : res.body;
  }

  /// Deletes the communal blob row [id]. Returns null on success or an error.
  Future<String?> _delete(String id) async {
    final debug = debugServerOverride;
    if (debug != null) {
      debug.remove(id);
      return null;
    }
    if (!RelayConfig.isEnabled) return _fail('No server configured.');
    final res = await http.delete(
      Uri.parse('${RelayConfig.supabaseUrl}/rest/v1/$table?id=eq.$id'),
      headers: {
        'apikey': RelayConfig.supabaseAnonKey,
        'Authorization': 'Bearer ${RelayConfig.supabaseAnonKey}',
      },
    ).timeout(const Duration(seconds: 15));
    if (res.statusCode >= 300) {
      return _fail('Delete failed (${res.statusCode}).');
    }
    return null;
  }

  /// Deletes the chat-backup object at [path] from the bucket. A missing
  /// object is success — there is nothing to delete.
  Future<String?> _deleteObject(String path) async {
    final debug = debugServerOverride;
    if (debug != null) {
      debug.remove(path);
      return null;
    }
    if (!RelayConfig.isEnabled) return _fail('No server configured.');
    final res = await http.delete(
      Uri.parse(
          '${RelayConfig.supabaseUrl}/storage/v1/object/$chatBucket/$path'),
      headers: {
        'apikey': RelayConfig.supabaseAnonKey,
        'Authorization': 'Bearer ${RelayConfig.supabaseAnonKey}',
      },
    ).timeout(const Duration(seconds: 30));
    if (res.statusCode == 404) return null; // already gone
    if (res.statusCode >= 300) {
      return _fail('Delete failed (${res.statusCode}).');
    }
    return null;
  }

  /// Erases everything this account has in the cloud: the communal blob AND
  /// the encrypted chat backup, both keyed off the sync key. Local data is
  /// untouched — this removes only what left the device. Returns null on
  /// success or a human-readable error.
  Future<String?> deleteCloudData() async {
    if (!configured) return 'Sign in (or set a sync passphrase) first.';
    syncing = true;
    lastError = null;
    notifyListeners();
    try {
      final key = await _syncKey();
      final blobErr = await _delete(blobIdFor(key));
      if (blobErr != null) return blobErr;
      // Chats live in the bucket under the chat key; clear them too, and zero
      // the quota meter so the plan reads empty afterwards.
      final chatErr = await _deleteObject(chatBlobIdFor(await _chatKey()));
      if (chatErr != null) return chatErr;
      await StorageStore.instance.setUsedBytes(0);
      lastSync = null;
      return null;
    } catch (_) {
      return _fail('Couldn\'t reach the server — check your connection.');
    } finally {
      syncing = false;
      notifyListeners();
    }
  }

  /// The stamp of the document this device most recently wrote or applied.
  ///
  /// Persisted, because the whole point is surviving a relaunch: without it
  /// every launch would re-apply the server's copy over local state that is
  /// already identical to it.
  DateTime? _syncedAt;
  DateTime? get syncedAt => _syncedAt;

  Future<void> _noteSynced(DateTime? at) async {
    if (at == null) return;
    _syncedAt = at;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kSyncedAt, at.toIso8601String());
    } catch (_) {}
  }

  /// Whether this device has successfully READ the server's copy this run.
  ///
  /// **Automatic uploads wait for it, and that is the whole safety of two-way
  /// sync.** A scheduled upload is not proof that anything changed — turning
  /// sync on schedules one, and so does a store notifying its listeners as it
  /// loads from disk — so a second device could push its empty slate over a
  /// good document before ever reading it. Nothing automatic goes up until
  /// the server has been read once.
  ///
  /// A MANUAL "Back up now" is deliberately exempt: that is somebody asking
  /// for it, and a device that can never reach the server to read must still
  /// be able to try to write when a person says so.
  bool _seenServer = false;
  bool get seenServer => _seenServer;

  /// Whether an automatic upload is queued. A test seam: [scheduleSync] sets
  /// an 8-second debounce, so asserting "nothing was uploaded" straight after
  /// calling it passes whether or not the upload was ever scheduled.
  @visibleForTesting
  bool get debugSyncPending => _debounce?.isActive == true;

  /// The blob, and whether the request itself succeeded — which `_get` cannot
  /// say, since it answers null for a missing row and for a failed call
  /// alike. The difference decides whether uploads may resume: "there is no
  /// document yet" is safe to push over, "I could not reach the server" is
  /// not.
  Future<({bool ok, String? data})> _fetchBlob(String id) async {
    final debug = debugServerOverride;
    if (debug != null) return (ok: true, data: debug[id]);
    if (!RelayConfig.isEnabled) return (ok: false, data: null);
    try {
      final res = await http.get(
        Uri.parse('${RelayConfig.supabaseUrl}/rest/v1/$table'
            '?id=eq.$id&select=data'),
        headers: {
          'apikey': RelayConfig.supabaseAnonKey,
          'Authorization': 'Bearer ${RelayConfig.supabaseAnonKey}',
        },
      ).timeout(const Duration(seconds: 15));
      if (res.statusCode >= 300) return (ok: false, data: null);
      final decoded = jsonDecode(res.body);
      if (decoded is List && decoded.isNotEmpty && decoded.first is Map) {
        return (ok: true, data: (decoded.first as Map)['data'] as String?);
      }
      return (ok: true, data: null);
    } catch (_) {
      return (ok: false, data: null);
    }
  }

  /// Brings down the server's copy when it is NEWER than what this device
  /// last wrote or applied.
  ///
  /// **This is what turns a backup into a sync.** The blob has always
  /// uploaded on every change, and only ever come back down through
  /// [restore] — which the automatic path ran solely when the device looked
  /// EMPTY (a fresh install). So a second device, or the same account after
  /// changing something on a phone and then opening the web build, simply
  /// diverged: both pushed, neither pulled, and whichever wrote last silently
  /// won. Everything now syncs because this runs at launch and on resume.
  ///
  /// **The honest limit, and it is inherent to a single-document design:**
  /// this is last-writer-wins over the WHOLE document. Two devices that both
  /// change things while offline do not merge — the one that uploads second
  /// wins outright, including for categories it never touched. Per-key
  /// merging would need a modification time per key, which SharedPreferences
  /// does not keep. Message HISTORY does not have this problem and is not
  /// carried here: `direct_messages` is a row per message, so two devices
  /// sending at once both land.
  ///
  /// Returns true when the server's copy was applied.
  Future<bool> pullIfNewer() async {
    if (!canSync) return false;
    try {
      final key = await _syncKey();
      // READ FIRST, ALWAYS. The first version of this flushed a pending
      // upload before reading, on the theory that an unsent local edit must
      // not be overwritten — and that was backwards in the direction that
      // loses data: a scheduled sync is not proof of an edit, so on a second
      // device it uploaded an EMPTY slate over a good document and then
      // found nothing newer to pull. Caught by the test that was meant to
      // prove two devices converge. Reading is free and cannot destroy
      // anything; deciding comes after.
      final fetched = await _fetchBlob(blobIdFor(key));
      // Could not reach the server: automatic uploads stay parked rather
      // than pushing over a copy this device has never read.
      if (!fetched.ok) return false;
      _seenServer = true;
      final data = fetched.data;
      // No document yet — this account's first device. Safe to push.
      if (data == null) return false;
      final plain = await compute(_decryptTask, (key: key, blob: data));
      if (plain == null) return false;
      final payload = jsonDecode(plain);
      if (payload is! Map<String, dynamic>) return false;
      final remoteAt = DateTime.tryParse(payload['at'] as String? ?? '');
      // A document with no stamp is from a build that predates this and
      // cannot be compared. Left alone rather than guessed at: applying it
      // could silently undo whatever this device has done since.
      if (remoteAt == null) return false;
      final mine = _syncedAt;
      if (mine != null && !remoteAt.isAfter(mine)) return false;
      await applyFullPayload(payload);
      await _noteSynced(remoteAt);
      lastError = null;
      notifyListeners();
      return true;
    } catch (_) {
      // Offline, or a passphrase that does not open it. Silent: this runs on
      // every launch and resume, and an error in front of somebody who asked
      // for nothing is worse than not syncing this time.
      return false;
    }
  }

  /// Uploads the communal data (servers, feed, follows, …). Free — no quota,
  /// no subscription. Returns null on success or a human-readable error.
  Future<String?> syncNow() async {
    if (!configured) return 'Sign in (or set a sync passphrase) first.';
    syncing = true;
    lastError = null;
    notifyListeners();
    try {
      final key = await _syncKey();
      final payload = await buildFullPayload();
      final data =
          await compute(_encryptTask, (key: key, plain: jsonEncode(payload)));
      final err = await _put(blobIdFor(key), data);
      if (err != null) return err;
      lastSync = DateTime.now();
      // What this device most recently WROTE. A pull only applies a document
      // stamped after this, so a device never re-applies its own upload.
      await _noteSynced(DateTime.tryParse(payload['at'] as String? ?? ''));
      return null;
    } catch (_) {
      return _fail('Couldn\'t reach the server — check your connection.');
    } finally {
      syncing = false;
      notifyListeners();
    }
  }

  /// Downloads and decrypts the communal blob, replacing local state.
  /// Free — no subscription. Returns null on success or a human-readable error.
  Future<String?> restore() async {
    if (!configured) return 'Sign in (or set a sync passphrase) first.';
    syncing = true;
    lastError = null;
    notifyListeners();
    try {
      final key = await _syncKey();
      final data = await _get(blobIdFor(key));
      if (data == null) return _fail('No backup found for this passphrase.');
      final plain = await compute(_decryptTask, (key: key, blob: data));
      if (plain == null) {
        return _fail('Wrong passphrase (or corrupted backup).');
      }
      final payload = jsonDecode(plain);
      if (payload is! Map<String, dynamic>) {
        return _fail('Backup is unreadable.');
      }
      await applyFullPayload(payload);
      lastSync = DateTime.now();
      // Same watermark the pull keeps, or the next launch would apply this
      // very document again over whatever has happened since.
      await _noteSynced(DateTime.tryParse(payload['at'] as String? ?? ''));
      return null;
    } catch (_) {
      return _fail('Couldn\'t reach the server — check your connection.');
    } finally {
      syncing = false;
      notifyListeners();
    }
  }

  // --- Chat backup: paid, personal, quota-metered ------------------------

  /// The chat backup rides a distinct blob id so it never collides with the
  /// communal one, even under the same key.
  static String chatBlobIdFor(Uint8List syncKey) {
    final mac = HMac(SHA256Digest(), 64)..init(KeyParameter(syncKey));
    final out = mac.process(Uint8List.fromList(utf8.encode('chat-blob-id')));
    return out.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// The chat backup document. Only ever chats.
  Map<String, dynamic> buildChatPayload() =>
      {'v': 1, 'chats': ChatStore.instance.toJson()};

  /// Plaintext size of the chat backup, for the quota meter.
  int chatBackupBytes() => utf8.encode(jsonEncode(buildChatPayload())).length;

  /// Backs up chats to paid storage. Requires a user passphrase (chats are
  /// never protected by the phone-derived key) and enough quota on the plan.
  Future<String?> backUpChats() async {
    if (!chatBackupReady) {
      return 'Set an encryption key first to back up chats.';
    }
    // Cheap guard so an over-quota backup is refused before doing the work.
    if (!StorageStore.instance.fits(chatBackupBytes())) {
      return 'Your chats are larger than your plan — upgrade to back them up.';
    }
    syncing = true;
    lastError = null;
    notifyListeners();
    try {
      final key = await _chatKey();
      final data = await compute(
          _encryptTask, (key: key, plain: jsonEncode(buildChatPayload())));
      if (!StorageStore.instance.fits(data.length)) {
        return _fail('Your chats are larger than your plan — upgrade to back '
            'them up.');
      }
      final err = await _putObject(chatBlobIdFor(key), data);
      if (err != null) return err;
      await StorageStore.instance.setUsedBytes(data.length);
      lastSync = DateTime.now();
      return null;
    } catch (_) {
      return _fail('Couldn\'t reach the server — check your connection.');
    } finally {
      syncing = false;
      notifyListeners();
    }
  }

  /// Restores chats from paid storage, replacing local chats.
  Future<String?> restoreChats() async {
    if (!chatBackupReady) {
      return 'Set your encryption key to restore chats.';
    }
    syncing = true;
    lastError = null;
    notifyListeners();
    try {
      final key = await _chatKey();
      final data = await _getObject(chatBlobIdFor(key));
      if (data == null) return _fail('No chat backup found for this key.');
      final plain = await compute(_decryptTask, (key: key, blob: data));
      if (plain == null) {
        return _fail('Wrong key (or corrupted chat backup).');
      }
      final payload = jsonDecode(plain);
      if (payload is Map && payload['chats'] is Map) {
        ChatStore.instance.hydrate(Map<String, dynamic>.from(payload['chats']));
        await StorageStore.instance.setUsedBytes(data.length);
        lastSync = DateTime.now();
        return null;
      }
      return _fail('The chat backup is unreadable.');
    } catch (_) {
      return _fail('Couldn\'t reach the server — check your connection.');
    } finally {
      syncing = false;
      notifyListeners();
    }
  }

  /// Health check for the chat backup: confirms it's present and decrypts,
  /// without touching local chats. Returns null when readable.
  Future<String?> verifyChatBackup() async {
    if (!chatBackupReady) return 'Set an encryption key first.';
    syncing = true;
    lastError = null;
    notifyListeners();
    try {
      final key = await _syncKey();
      final data = await _getObject(chatBlobIdFor(key));
      if (data == null) return _fail('No chat backup yet — back up first.');
      final plain = await compute(_decryptTask, (key: key, blob: data));
      if (plain == null) {
        return _fail('The chat backup couldn\'t be decrypted with this key.');
      }
      final payload = jsonDecode(plain);
      if (payload is! Map || payload['chats'] is! Map) {
        return _fail('The chat backup is present but unreadable.');
      }
      await StorageStore.instance.setUsedBytes(data.length);
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

  /// The account digits the current key is salted with.
  @visibleForTesting
  String get digitsForTest => _digits;

  /// Derives a sync key the same way the store does, for tests that need to
  /// predict a blob's object name.
  @visibleForTesting
  static Future<Uint8List> deriveSyncKeyForTest(
          String passphrase, String digits) async =>
      compute(_deriveKeyTask, (pass: passphrase, digits: digits));

  @visibleForTesting
  void resetForTest() {
    _enabled = false;
    _passphrase = '';
    // Asked-once is per account, not per device: a different account arriving
    // on this phone has its own chat backup to be asked about, and this is
    // the reset an account switch runs.
    _asked = false;
    // The sync watermark belongs to the account too: a different account's
    // document is not one this device has already applied.
    _syncedAt = null;
    _seenServer = false;
    _bootstrappedFor = '';
    _keyCache = null;
    _keyCacheFor = '';
    // The PIN route is per account too — it is derived from the identity
    // key, and the next account on this phone has a different one.
    _pinChats = false;
    _chatKeyCache = null;
    lastSync = null;
    lastError = null;
    _debounce?.cancel();
    // Detach the store listeners so a later test's store change (or a
    // debugActivate) can't fire a stray autoBootstrap into this instance.
    if (_listening) {
      FeedStore.instance.removeListener(scheduleSync);
      FollowStore.instance.removeListener(scheduleSync);
      SavedPlacesStore.instance.removeListener(scheduleSync);
      ContactsStore.instance.removeListener(scheduleSync);
      CommunityStore.instance.removeListener(scheduleSync);
      ScoreStore.instance.removeListener(scheduleSync);
      AppState.profile.removeListener(autoBootstrap);
      _listening = false;
    }
  }
}
