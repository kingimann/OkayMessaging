import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide Session;

import '../relay/relay_config.dart';
import 'e2e.dart';

/// Encryption recovery, the way Messenger's PIN and WhatsApp's 64-digit key
/// do it: the identity private key is sealed under a code only the user
/// holds, and the sealed blob — never the key — is stored server-side. A new
/// device (or a reinstall) that enters the code gets the SAME identity back,
/// so everything sealed to it still opens and no peer ever sees a key change.
///
/// This is the root fix for "sealed to a key this device no longer has":
/// that message exists because a reinstall mints a fresh identity and the
/// old one is gone from the universe. With a recovery code, it isn't.
///
/// The seal is the same construction as the encrypted backup: PBKDF2-HMAC-
/// SHA256 over a per-blob random salt, then AES-256-GCM. The code is minted
/// by the app — 16 characters from a 32-letter alphabet (80 bits), never a
/// user-chosen word — so the blob resists offline guessing even if the
/// server row leaks. Losing the code means the backup is unreadable, by
/// everyone including us; that is the deal, and the UI says so.
class IdentityRecovery {
  IdentityRecovery._();

  /// No 0/O, no 1/I — a code someone reads back over the phone or off a
  /// sticky note must not have two characters that print the same.
  static const String alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  /// Whether this device has a recovery code squared away — created here, or
  /// typed in to restore. X's rule for encrypted DMs, adopted: messaging
  /// waits until this is true, because the one moment a backup can still be
  /// made is BEFORE the phone that holds the only keys is lost.
  static final ValueNotifier<bool> ready = ValueNotifier<bool>(false);
  static const String _kReady = 'recovery_ready_v1';

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    ready.value = prefs.getBool(_kReady) ?? false;
  }

  static Future<void> markReady() async {
    ready.value = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kReady, true);
  }

  @visibleForTesting
  static void resetReadyForTest() => ready.value = false;

  /// Matches the encrypted backup's stretch, for the same reason it is that
  /// high there: this blob's only defense after a leak is the derivation.
  static const int iterations = 120000;

  static const String _appTag = 'okay-identity';

  static final Random _rng = Random.secure();

  /// A fresh recovery code, grouped for reading: `XXXX-XXXX-XXXX-XXXX`.
  static String mintCode() {
    final chars = List.generate(
        16, (_) => alphabet[_rng.nextInt(alphabet.length)]);
    return [
      for (var i = 0; i < 16; i += 4) chars.sublist(i, i + 4).join(),
    ].join('-');
  }

  /// What the user typed, forgiven: case, spaces and separators all drop
  /// out, so `abcd efgh…` and `ABCD-EFGH…` are the same code.
  static String normalize(String raw) =>
      raw.toUpperCase().replaceAll(RegExp('[^$alphabet]'), '');

  static Uint8List _randomBytes(int n) =>
      Uint8List.fromList(List.generate(n, (_) => _rng.nextInt(256)));

  static List<int> _deriveKey(String code, Uint8List salt) {
    final d = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(Pbkdf2Parameters(salt, iterations, 32));
    return d.process(Uint8List.fromList(utf8.encode(normalize(code))));
  }

  /// Seals the identity private key under [code] into a self-describing
  /// archive. [salt] is injectable for deterministic tests.
  static String sealIdentity(String privateHex, String code,
      {Uint8List? salt}) {
    final s = salt ?? _randomBytes(16);
    return jsonEncode({
      'app': _appTag,
      'v': 1,
      'kdf': 'pbkdf2-sha256',
      'iter': iterations,
      'salt': base64.encode(s),
      'data': E2eCrypto.encrypt(_deriveKey(code, s), privateHex),
    });
  }

  /// Reverses [sealIdentity]: the private key hex, or null when the archive
  /// is malformed, tampered with, or the code is wrong — GCM cannot tell
  /// those apart, and neither can the caller, so the message to the user is
  /// always "wrong code or no backup".
  static String? openIdentity(String archive, String code) {
    try {
      final env = jsonDecode(archive) as Map<String, dynamic>;
      if (env['app'] != _appTag) return null;
      final salt = base64.decode(env['salt'] as String);
      return E2eCrypto.decrypt(_deriveKey(code, salt), env['data'] as String);
    } catch (_) {
      return null;
    }
  }

  /// Numberless accounts are addressed by minted codes with a '00' prefix a
  /// real E.164 number can never have — the same split the directory and
  /// push registration key off.
  static bool isNumberless(String digitsInbox) => digitsInbox.startsWith('00');

  /// Test stand-ins for the two server calls.
  @visibleForTesting
  static Future<bool> Function(String inbox, String blob)? debugStore;
  @visibleForTesting
  static Future<String?> Function(String inbox)? debugFetch;

  /// Puts the sealed [blob] where a future device can find it. Phone
  /// accounts ride their session — RLS pins the row to the JWT's own number,
  /// so nobody can plant or replace anybody else's backup. Numberless
  /// accounts have no session and go through an RPC that only ever touches
  /// '00' rows, first write wins.
  static Future<bool> store(String digitsInbox, String blob) async {
    final debug = debugStore;
    if (debug != null) return debug(digitsInbox, blob);
    if (!RelayConfig.isEnabled || digitsInbox.isEmpty) return false;
    try {
      final client = Supabase.instance.client;
      if (isNumberless(digitsInbox)) {
        final ok = await client.rpc('put_identity_backup',
            params: {'inboxv': digitsInbox, 'blobv': blob});
        return ok == true;
      }
      await client.from('identity_backups').upsert({
        'inbox': digitsInbox,
        'blob': blob,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  /// The sealed blob for [digitsInbox], or null when there is none (or it
  /// cannot be reached). The blob is useless without the code either way.
  static Future<String?> fetch(String digitsInbox) async {
    final debug = debugFetch;
    if (debug != null) return debug(digitsInbox);
    if (!RelayConfig.isEnabled || digitsInbox.isEmpty) return null;
    try {
      final client = Supabase.instance.client;
      if (isNumberless(digitsInbox)) {
        final blob = await client
            .rpc('get_identity_backup', params: {'inboxv': digitsInbox});
        return blob is String && blob.isNotEmpty ? blob : null;
      }
      final row = await client
          .from('identity_backups')
          .select('blob')
          .eq('inbox', digitsInbox)
          .maybeSingle();
      final blob = row?['blob'];
      return blob is String && blob.isNotEmpty ? blob : null;
    } catch (_) {
      return null;
    }
  }
}
