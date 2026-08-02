import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A password on a single conversation, and — if you ask for it — the
/// conversation's absence from the list entirely.
///
/// **Every chat has its own password.** Not one password for "locked chats":
/// each lock is its own credential, so opening one tells you nothing about the
/// others and there is no single answer that opens everything. It is also
/// nothing to do with the app PIN ([AppLock]) — that one keeps a stranger out
/// of the app, this one keeps somebody who is already holding your unlocked
/// phone out of one conversation. A PIN that opened chats too would collapse
/// those into one secret.
///
/// **What this is not.** The messages are not re-encrypted behind the
/// password: they sit in the same local store as every other chat, protected
/// by the device's own encryption and nothing else. This gates the app's own
/// way in. Somebody with the unlocked phone, a copy of its disk and the
/// patience to read it is outside what this stops, and saying otherwise would
/// be the kind of promise that gets people hurt. What it does stop is the
/// person who picks up your phone.
///
/// The password is never stored. PBKDF2-HMAC-SHA256 over a per-chat random
/// salt is, which is the same derivation the encrypted backup uses — a guess
/// costs the full round count, so a stolen preferences file is not a list to
/// run a dictionary against in an afternoon.
class ChatLock extends ChangeNotifier {
  ChatLock._();
  static final ChatLock instance = ChatLock._();

  static const _key = 'chat_locks_v1';

  /// PBKDF2 rounds. The same order as the backup's, and paid once per unlock
  /// rather than per keystroke.
  static const int rounds = 120000;

  /// Lowered in tests so a suite that unlocks a dozen chats does not spend
  /// its minute in a key derivation whose cost is the point.
  @visibleForTesting
  static int? debugRounds;

  final Map<String, _Lock> _locks = {};

  /// Chats opened with their password since the app started. Deliberately not
  /// persisted: a lock that survives being closed and reopened is a lock that
  /// asks once and never again.
  final Set<String> _open = {};

  SharedPreferences? _prefs;

  Future<void> load() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    _locks.clear();
    _open.clear();
    final raw = prefs.getString(_key);
    if (raw != null) {
      try {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        for (final e in map.entries) {
          final lock = _Lock.fromJson(e.value);
          if (lock != null) _locks[e.key] = lock;
        }
      } catch (_) {
        // Unreadable state must never lock somebody out of every chat they
        // have. An unparseable blob means no locks, not all locks.
      }
    }
    notifyListeners();
  }

  /// Whether [chatId] has a password on it.
  bool isLocked(String chatId) => _locks.containsKey(chatId);

  /// Whether [chatId] is kept out of the chat list altogether.
  bool isHidden(String chatId) => _locks[chatId]?.hidden ?? false;

  /// Whether [chatId] has been opened with its password this session. Always
  /// true for a chat with no lock, so callers can ask this one question.
  bool isOpen(String chatId) => !isLocked(chatId) || _open.contains(chatId);

  /// Chats that should not appear anywhere until their password is typed:
  /// hidden, and not opened yet.
  bool isConcealed(String chatId) => isHidden(chatId) && !_open.contains(chatId);

  int get lockedCount => _locks.length;
  int get hiddenCount => _locks.values.where((l) => l.hidden).length;

  /// Puts [password] on [chatId]. Also opens it for this session — locking a
  /// chat and then being asked to prove who you are is a lock arguing with
  /// the person who set it.
  Future<void> lock(String chatId, String password,
      {bool hidden = false}) async {
    final salt = _salt();
    _locks[chatId] = _Lock(
      salt: salt,
      hash: await _hashAsync(password, salt),
      hidden: hidden,
    );
    _open.add(chatId);
    await _save();
  }

  /// Removes the lock from [chatId], given its password. Returns false and
  /// changes nothing when the password is wrong — otherwise "unlock" would be
  /// a way past the lock rather than a use of it.
  Future<bool> removeLock(String chatId, String password) async {
    if (!await verify(chatId, password)) return false;
    _locks.remove(chatId);
    _open.remove(chatId);
    await _save();
    return true;
  }

  /// Whether [password] is [chatId]'s. Free of side effects, so a caller can
  /// ask without opening anything.
  Future<bool> verify(String chatId, String password) async {
    final lock = _locks[chatId];
    if (lock == null) return false;
    return _constantTimeEquals(
        await _hashAsync(password, lock.salt), lock.hash);
  }

  /// Opens [chatId] for this session. Returns false on a wrong password.
  Future<bool> open(String chatId, String password) async {
    if (!await verify(chatId, password)) return false;
    _open.add(chatId);
    notifyListeners();
    return true;
  }

  /// Every hidden chat [password] opens — usually one, and never more than
  /// one unless the same password was used twice.
  ///
  /// This is how a hidden chat is reached: there is nothing to tap, so the
  /// password itself is the way in. Only hidden chats are considered, because
  /// a locked-but-visible chat already has a row to tap.
  Future<List<String>> revealHidden(String password) async {
    if (password.trim().isEmpty) return const [];
    final found = <String>[];
    for (final e in _locks.entries) {
      if (!e.value.hidden) continue;
      if (_constantTimeEquals(
          await _hashAsync(password, e.value.salt), e.value.hash)) {
        found.add(e.key);
      }
    }
    if (found.isNotEmpty) {
      _open.addAll(found);
      notifyListeners();
    }
    return found;
  }

  /// Shuts every chat that was opened this session. Called when the app goes
  /// to the background: a chat opened an hour ago and left on screen is one
  /// the password stopped protecting.
  void closeAll() {
    if (_open.isEmpty) return;
    _open.clear();
    notifyListeners();
  }

  /// Changes whether a locked chat is also hidden.
  ///
  /// Takes no password, and requires the chat to be OPEN this session — which
  /// is the same proof, already given. Asking again would be asking somebody
  /// who is looking at the conversation to prove they may look at it.
  Future<bool> setHidden(String chatId, bool hidden) async {
    final lock = _locks[chatId];
    if (lock == null || !_open.contains(chatId)) return false;
    _locks[chatId] = lock.copyWith(hidden: hidden);
    await _save();
    return true;
  }

  /// Drops any lock on [chatId] without a password — for a chat being deleted,
  /// where the lock has nothing left to protect and would otherwise be an
  /// entry nobody can ever clear.
  Future<void> forget(String chatId) async {
    if (_locks.remove(chatId) == null) return;
    _open.remove(chatId);
    await _save();
  }

  /// [hashFor], off the main isolate.
  ///
  /// 120k rounds is 200-400ms of solid arithmetic, and on the UI thread that
  /// is a frozen screen at the exact moment somebody is typing a password —
  /// with no spinner possible, because the thread that would draw it is the
  /// one doing the work. Every path that checks a password goes through here.
  static Future<String> _hashAsync(String password, String salt) {
    // A test lowers the rounds to make the suite finish, which leaves the
    // isolate hop costing far more than the work inside it — `compute` loads
    // the program into a fresh isolate per call, and thirty of those is
    // minutes. At one round there is nothing to keep off the UI thread.
    if (debugRounds != null) {
      return Future.value(hashFor(password, salt));
    }
    return compute(_hashJob, [password, salt, rounds]);
  }

  /// PBKDF2-HMAC-SHA256, the same derivation the encrypted backup uses.
  /// Static and pure so a test can check it without a store behind it.
  static String hashFor(String password, String salt) {
    final kdf = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(Pbkdf2Parameters(
          Uint8List.fromList(utf8.encode('okay-chat-lock|$salt')),
          debugRounds ?? rounds,
          32));
    return base64.encode(kdf.process(Uint8List.fromList(utf8.encode(password))));
  }

  /// Compares without leaking where two hashes first differ. Overkill against
  /// a local attacker with the file, and free.
  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  static String _salt() {
    final rng = Random.secure();
    return base64.encode(List.generate(16, (_) => rng.nextInt(256)));
  }

  Future<void> _save() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    await prefs.setString(
        _key, jsonEncode({for (final e in _locks.entries) e.key: e.value.toJson()}));
    notifyListeners();
  }

  @visibleForTesting
  void resetForTest() {
    _locks.clear();
    _open.clear();
    _prefs = null;
    debugRounds = 1;
    notifyListeners();
  }
}

class _Lock {
  final String salt;
  final String hash;
  final bool hidden;

  const _Lock({required this.salt, required this.hash, required this.hidden});

  _Lock copyWith({bool? hidden}) =>
      _Lock(salt: salt, hash: hash, hidden: hidden ?? this.hidden);

  Map<String, dynamic> toJson() =>
      {'salt': salt, 'hash': hash, 'hidden': hidden};

  static _Lock? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final salt = raw['salt'] as String?;
    final hash = raw['hash'] as String?;
    if (salt == null || hash == null) return null;
    return _Lock(salt: salt, hash: hash, hidden: raw['hidden'] == true);
  }
}

/// The isolate side of [ChatLock._hashAsync]. Top-level because `compute`
/// requires it, and it takes the round count in its payload rather than
/// reading the static: an isolate gets its own copy of everything static, so
/// a test's lowered round count would not cross into it.
String _hashJob(List<Object> args) {
  final saved = ChatLock.debugRounds;
  ChatLock.debugRounds = args[2] as int;
  try {
    return ChatLock.hashFor(args[0] as String, args[1] as String);
  } finally {
    ChatLock.debugRounds = saved;
  }
}
