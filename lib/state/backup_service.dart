import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_state.dart';
import '../crypto/e2e.dart';
import '../models/user.dart';
import 'chat_store.dart';
import 'community_store.dart';
import 'session.dart';

/// How often the app should nudge the user to back up.
enum BackupReminder {
  off,
  daily,
  weekly,
  monthly;

  String get label => switch (this) {
        BackupReminder.off => 'Off',
        BackupReminder.daily => 'Daily',
        BackupReminder.weekly => 'Weekly',
        BackupReminder.monthly => 'Monthly',
      };

  /// The interval after which a backup is considered overdue (null when off).
  Duration? get interval => switch (this) {
        BackupReminder.off => null,
        BackupReminder.daily => const Duration(days: 1),
        BackupReminder.weekly => const Duration(days: 7),
        BackupReminder.monthly => const Duration(days: 30),
      };

  static BackupReminder fromName(String? n) => BackupReminder.values
      .firstWhere((r) => r.name == n, orElse: () => BackupReminder.off);
}

/// Creates and restores an **end-to-end encrypted** backup of the user's chats
/// and profile, so it can be stored on iCloud Drive, Dropbox, or Google Drive
/// without exposing anything. The backup is encrypted with a passphrase only
/// the user knows: a key is stretched from it via PBKDF2-HMAC-SHA256 (with a
/// per-backup random salt), then the payload is sealed with AES-256-GCM. Losing
/// the passphrase means the backup can't be recovered — no one else can read
/// it, not Okay and not the cloud provider.
class BackupService extends ChangeNotifier {
  BackupService._();
  static final BackupService instance = BackupService._();

  static const _appTag = 'okay-messaging-backup';
  static const _version = 1;
  static const int iterations = 120000;
  static const _kLastBackup = 'last_backup_at';
  static const _kReminder = 'backup_reminder';

  SharedPreferences? _prefs;

  /// When the last successful backup was created (null if never).
  DateTime? lastBackupAt;

  /// How often to nudge the user to back up.
  BackupReminder reminder = BackupReminder.off;

  Future<void> load() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    final raw = prefs.getString(_kLastBackup);
    lastBackupAt = raw == null ? null : DateTime.tryParse(raw);
    reminder = BackupReminder.fromName(prefs.getString(_kReminder));
    notifyListeners();
  }

  /// Sets the reminder cadence and persists it.
  void setReminder(BackupReminder value) {
    reminder = value;
    _prefs?.setString(_kReminder, value.name);
    notifyListeners();
  }

  /// Whether a backup is overdue given the reminder cadence: true when a
  /// reminder is set and either no backup exists yet or the last one is older
  /// than the interval.
  bool isBackupDue({DateTime? now}) {
    final interval = reminder.interval;
    if (interval == null) return false;
    if (lastBackupAt == null) return true;
    return (now ?? DateTime.now()).difference(lastBackupAt!) >= interval;
  }

  void _markBackedUp(DateTime when) {
    lastBackupAt = when;
    _prefs?.setString(_kLastBackup, when.toIso8601String());
    notifyListeners();
  }

  static final _rng = Random.secure();

  static Uint8List _randomBytes(int n) =>
      Uint8List.fromList(List.generate(n, (_) => _rng.nextInt(256)));

  /// Derives a 32-byte key from [passphrase] and [salt] using PBKDF2.
  static List<int> _deriveKey(String passphrase, Uint8List salt, int iter) {
    final d = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(Pbkdf2Parameters(salt, iter, 32));
    return d.process(Uint8List.fromList(utf8.encode(passphrase)));
  }

  /// The plaintext bundle a backup contains: every conversation, the servers
  /// (communities) you belong to, and your profile.
  static String buildBundle() => jsonEncode({
        'chats': ChatStore.instance.toJson(),
        'communities': CommunityStore.instance.toJsonList(),
        'profile': AppState.profile.value.toJson(),
      });

  /// Encrypts [bundleJson] into a portable, self-describing archive string.
  /// A [salt] and [createdAt] can be supplied for deterministic tests.
  static String encryptArchive(
    String bundleJson,
    String passphrase, {
    Uint8List? salt,
    String? createdAt,
  }) {
    final s = salt ?? _randomBytes(16);
    final key = _deriveKey(passphrase, s, iterations);
    return jsonEncode({
      'app': _appTag,
      'v': _version,
      'kdf': 'pbkdf2-sha256',
      'iter': iterations,
      'salt': base64.encode(s),
      'createdAt': createdAt,
      'data': E2eCrypto.encrypt(key, bundleJson),
    });
  }

  /// Reverses [encryptArchive]: returns the decrypted bundle JSON, or null when
  /// the archive is malformed or the passphrase is wrong.
  static String? decryptArchive(String archiveJson, String passphrase) {
    try {
      final env = jsonDecode(archiveJson) as Map<String, dynamic>;
      if (env['app'] != _appTag) return null;
      final salt = base64.decode(env['salt'] as String);
      final iter = (env['iter'] as num?)?.toInt() ?? iterations;
      final key = _deriveKey(passphrase, salt, iter);
      return E2eCrypto.decrypt(key, env['data'] as String);
    } catch (_) {
      return null;
    }
  }

  /// Restores a decrypted [bundleJson] into the app, replacing local chats and
  /// profile. Returns true on success.
  static bool applyBundle(String bundleJson) {
    try {
      final m = jsonDecode(bundleJson) as Map<String, dynamic>;
      final chats = m['chats'];
      if (chats is Map) {
        ChatStore.instance.hydrate(Map<String, dynamic>.from(chats));
      }
      final communities = m['communities'];
      if (communities is List) {
        CommunityStore.instance.hydrate(communities);
      }
      final profile = m['profile'];
      if (profile is Map) {
        AppState.profile.value =
            AppUser.fromJson(Map<String, dynamic>.from(profile));
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Builds an encrypted archive of the current data as UTF-8 bytes, stamping
  /// the last-backup time. Used by the UI before handing the bytes to the
  /// share sheet / download.
  Uint8List createArchiveBytes(String passphrase, {DateTime? now}) {
    final when = now ?? DateTime.now();
    final archive = encryptArchive(
      buildBundle(),
      passphrase,
      createdAt: when.toIso8601String(),
    );
    _markBackedUp(when);
    return Uint8List.fromList(utf8.encode(archive));
  }

  /// Decrypts [archiveBytes] with [passphrase] and restores it. Returns true on
  /// success. Also re-persists the profile to the signed-in identity.
  Future<bool> restoreFromBytes(Uint8List archiveBytes, String passphrase) async {
    final String archive;
    try {
      archive = utf8.decode(archiveBytes);
    } catch (_) {
      return false;
    }
    final bundle = decryptArchive(archive, passphrase);
    if (bundle == null) return false;
    final ok = applyBundle(bundle);
    if (ok && Session.instance.isSignedIn) {
      final me = AppState.profile.value;
      await Session.instance.updateProfile(
        name: me.name,
        about: me.about,
        username: me.username,
        avatarColor: me.avatarColor,
      );
    }
    return ok;
  }

  @visibleForTesting
  void resetForTest() {
    lastBackupAt = null;
    reminder = BackupReminder.off;
    _prefs = null;
    notifyListeners();
  }
}
