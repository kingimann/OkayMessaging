// The stores' resetForTest() methods are exactly "drop every trace of this
// account from memory", which is what an account switch needs and the one
// production event that legitimately does. Duplicating twenty-five
// clear-for-switch methods would drift the first time a store changed;
// reusing the resets cannot.
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../app_state.dart';
import '../crypto/double_ratchet.dart';
import '../crypto/identity_recovery.dart';
import '../crypto/key_exchange.dart';
import '../crypto/sender_key.dart';
import 'secure_store.dart';
import 'account_email.dart';
import 'backup_prefs.dart';
import 'backup_service.dart';
import 'bookmark_store.dart';
import 'chat_folders.dart';
import 'pending_server_invites.dart';
import 'qr_style_store.dart';
import 'inbox_tiers.dart';
import 'message_sound_store.dart';
import 'saved_forms.dart';
import 'vehicle_inspections.dart';
import 'nwc_store.dart';
import 'call_log.dart';
import 'chat_lock.dart';
import 'chat_store.dart';
import 'cloud_sync.dart';
import 'ai_assistant.dart';
import 'ai_consent.dart';
import 'ai_memory.dart';
import 'ai_pass_store.dart';
import 'community_store.dart';
import 'community_sub_store.dart';
import 'creator_sub_store.dart';
import 'favourites_store.dart';
import 'feed_drafts.dart';
import 'feed_mute_store.dart';
import 'feed_prefs.dart';
import 'feed_store.dart';
import 'follow_store.dart';
import 'identity_verification.dart';
import 'contacts_store.dart';
import 'live_share_store.dart';
import 'notes_store.dart';
import 'payment_security_store.dart';
import 'persistence.dart';
import 'password_history.dart';
import 'quick_replies.dart';
import 'recent_searches.dart';
import 'saved_places_store.dart';
import 'scheduler.dart';
import 'score_store.dart';
import 'sidebar_prefs.dart';
import 'status_store.dart';
import 'sticker_store.dart';
import 'storage_store.dart';
import 'streak_store.dart';
import 'two_step.dart';
import 'public_feed_alerts.dart';
import 'watch_history.dart';
import 'weather_cities_store.dart';

/// Keeps each account's data separate on a shared device, WITHOUT the two
/// accounts ever seeing each other.
///
/// Every store here is device-scoped, which is right while one account owns
/// the screen and catastrophic the moment a second one is looking at it: a
/// fresh account would inherit the last one's chats, verification badge,
/// score, feed — everything. Signing back into the SAME account keeps its
/// data (that is the "chats stay on the device" promise); switching to a
/// DIFFERENT account must show that account's data and nothing of the last.
///
/// The old mechanism DESTROYED the leaving account's data on a switch, so a
/// device with two accounts could only ever hold one at a time — switching
/// back meant starting over. This one PARKS it instead: on a switch the whole
/// account bundle (its SharedPreferences slice and its keychain material) is
/// archived under the owner's digits, the arriving account's bundle is brought
/// back if the device has it, and every in-memory singleton is rebuilt from
/// the swapped storage. Same account returning → its data is exactly where it
/// left it; different account → a clean slate that shows nothing of the other.
///
/// The honest cost, chosen deliberately: both accounts' data now co-reside on
/// the device's disk, so a forensic dump could recover a departed account's
/// data that the old destroy-on-switch would have erased. **Delete account**
/// ([eraseCurrentAccount]) erases the signed-in account and only it, leaving
/// the other accounts parked here alone.
class AccountWipe {
  AccountWipe._();

  /// What is NOT part of any one account's data bundle: the device's own
  /// settings, the terms the HUMAN accepted, and the login screen's list of
  /// who has signed in here. These stay put across a switch.
  static const Set<String> keepKeys = {
    'theme',
    'app_lock_hash_v1',
    'app_lock_salt_v1',
    'legal_accepted_version_v1',
    'onboarding_done_v1',
    'last_account_v1',
    // Who has signed in on this device (identity only, never their data) —
    // the login screen's one-tap way back into each. Same standing as
    // last_account_v1, list-shaped.
    'known_accounts_v1',
    // The device's abuse history — how many accounts it has minted and which
    // have signed in here — belongs to the PHONE, not any one account, so it
    // survives a switch (else switching accounts would reset the spam-signup
    // brake). See AbuseGuard.
    'abuse_account_creates_v1',
    'abuse_accounts_seen_v1',
  };

  /// Where the digits of the current owner live, so the next sign-in can
  /// tell "same account returning" from "different account arriving".
  static const ownerKey = 'owner_digits_v1';

  /// The keychain items that belong to the identity, not the device: the
  /// device private key, the Double Ratchet sessions, the sender-key chains.
  /// Archived and restored alongside the prefs slice so a returning account's
  /// crypto — and therefore its ability to keep reading its chats — comes back
  /// with it, instead of being regenerated as a stranger.
  static const List<String> _secureKeys = [
    'device_ec_priv',
    'double_ratchet',
    'sender_keys',
  ];

  static String _digits(String phone) => phone.replaceAll(RegExp(r'\D'), '');

  /// The prefs key each account's parked bundle lives under.
  static String _archiveKey(String digits) => 'acct_ns_$digits';

  /// Whether [key] belongs to the device rather than to whichever account is
  /// signed in — the keep-list, the owner marker, and the archives themselves
  /// (an archive must survive the clear that empties the live slot).
  static bool _isDeviceScoped(String key) =>
      keepKeys.contains(key) ||
      key == ownerKey ||
      key.startsWith('acct_ns_');

  /// Parks the leaving account and brings back the arriving one if [nextPhone]
  /// is not the account the device currently belongs to, recording the new
  /// owner either way. Call BEFORE persisting the new identity.
  static Future<void> onSignIn(String nextPhone) async {
    final prefs = await SharedPreferences.getInstance();
    final previous = prefs.getString(ownerKey) ?? '';
    final next = _digits(nextPhone);
    if (previous.isNotEmpty && previous != next) {
      await _switchOwner(prefs, previous, next);
    }
    await prefs.setString(ownerKey, next);
  }

  /// Archives [previous]'s bundle, empties the live slot, restores [next]'s
  /// bundle (if the device has it), then rebuilds every singleton from disk.
  ///
  /// The ORDER is load-bearing. The in-memory reset has to run BEFORE the
  /// disk is restored, not after: some singletons persist through an auto-save
  /// listener (AppState settings and the profile, and the chat store), so
  /// resetting them writes their defaults straight back to disk. Reset first,
  /// then clear, then restore, then read the restored disk back into memory —
  /// so the restore is the LAST thing to touch disk, not overwritten by a
  /// reset that came after it.
  static Future<void> _switchOwner(
      SharedPreferences prefs, String previous, String next) async {
    // Park the leaving account's whole bundle under its digits — captured from
    // disk while it is still the live account's.
    final leaving = await _snapshotLive(prefs);
    await prefs.setString(_archiveKey(previous), jsonEncode(leaving));

    // The device-scoped keys, captured now because the reset below can write
    // one of them back (the theme rides an AppState auto-save listener).
    final kept = _snapshotKept(prefs);

    // Memory first: drop the leaving account out of every singleton. This
    // fires the auto-save listeners, writing defaults to the live slot — which
    // is about to be cleared and restored anyway.
    _resetAllSingletons();

    // Empty the live slot, then bring the arriving account's bundle back if
    // this device has one parked.
    await _clearLive(prefs);
    final incoming = prefs.getString(_archiveKey(next));
    if (incoming != null) {
      try {
        await _restoreLive(
            prefs, jsonDecode(incoming) as Map<String, dynamic>);
      } catch (_) {}
      await prefs.remove(_archiveKey(next));
    }

    // Put back any device-scoped key the reset trampled, then read the
    // restored disk into memory (the LAST touch, so nothing overwrites it).
    await _restoreKept(prefs, kept);
    await _loadAllFromDisk();
  }

  static Map<String, Object> _snapshotKept(SharedPreferences prefs) {
    final kept = <String, Object>{};
    for (final k in keepKeys) {
      final v = prefs.get(k);
      if (v != null) kept[k] = v;
    }
    return kept;
  }

  static Future<void> _restoreKept(
      SharedPreferences prefs, Map<String, Object> kept) async {
    for (final e in kept.entries) {
      final v = e.value;
      if (v is String) await prefs.setString(e.key, v);
      if (v is bool) await prefs.setBool(e.key, v);
      if (v is int) await prefs.setInt(e.key, v);
      if (v is double) await prefs.setDouble(e.key, v);
      if (v is List<String>) await prefs.setStringList(e.key, v);
    }
  }

  /// Captures the live account's SharedPreferences slice (everything that is
  /// not device-scoped) and its keychain material, ready to be JSON-parked.
  static Future<Map<String, dynamic>> _snapshotLive(
      SharedPreferences prefs) async {
    final data = <String, dynamic>{};
    for (final key in prefs.getKeys()) {
      if (_isDeviceScoped(key)) continue;
      final v = prefs.get(key);
      if (v is String) {
        data[key] = {'t': 's', 'v': v};
      } else if (v is bool) {
        data[key] = {'t': 'b', 'v': v};
      } else if (v is int) {
        data[key] = {'t': 'i', 'v': v};
      } else if (v is double) {
        data[key] = {'t': 'd', 'v': v};
      } else if (v is List) {
        data[key] = {'t': 'l', 'v': v.cast<String>()};
      }
    }
    final sec = <String, String>{};
    for (final k in _secureKeys) {
      final val = await SecureStore.instance.read(k);
      if (val != null) sec[k] = val;
    }
    return {'prefs': data, 'sec': sec};
  }

  /// Removes the live account's slice from prefs and the keychain, keeping the
  /// device-scoped keys and every parked archive.
  static Future<void> _clearLive(SharedPreferences prefs) async {
    for (final key in prefs.getKeys().toList()) {
      if (_isDeviceScoped(key)) continue;
      await prefs.remove(key);
    }
    for (final k in _secureKeys) {
      await SecureStore.instance.delete(k);
    }
  }

  /// Writes a parked bundle back into the live slot.
  static Future<void> _restoreLive(
      SharedPreferences prefs, Map<String, dynamic> blob) async {
    final data = (blob['prefs'] as Map?) ?? const {};
    for (final e in data.entries) {
      final rec = e.value as Map;
      final key = e.key as String;
      final v = rec['v'];
      switch (rec['t']) {
        case 's':
          await prefs.setString(key, v as String);
          break;
        case 'b':
          await prefs.setBool(key, v as bool);
          break;
        case 'i':
          await prefs.setInt(key, (v as num).toInt());
          break;
        case 'd':
          await prefs.setDouble(key, (v as num).toDouble());
          break;
        case 'l':
          await prefs.setStringList(key, (v as List).cast<String>());
          break;
      }
    }
    final sec = (blob['sec'] as Map?) ?? const {};
    for (final e in sec.entries) {
      await SecureStore.instance.write(e.key as String, e.value as String);
    }
  }

  /// Erases the CURRENT account from this device, for **Delete account** —
  /// and only that account. On a shared device the other accounts parked
  /// here (their archives), the device's own settings and PIN, and the terms
  /// the human accepted all stay: deleting one identity must not wipe the
  /// person's other identities or reset the phone. The current account's live
  /// slice — chats, servers, notes, keys, its profile — is cleared from both
  /// memory and disk, and its own parked archive (if it somehow had one) with
  /// it. The [ownerKey] is deliberately LEFT as the deleted digits so a
  /// different account signing in next still detects the change and restores
  /// its own parked data.
  static Future<void> eraseCurrentAccount() async {
    final prefs = await SharedPreferences.getInstance();
    final kept = _snapshotKept(prefs); // the reset can trample the theme
    _resetAllSingletons(); // the account's data, out of memory
    await _clearLive(prefs); // its prefs slice and keychain material, off disk
    await _restoreKept(prefs, kept); // keep the shared device settings intact
    final digits = prefs.getString(ownerKey) ?? '';
    if (digits.isNotEmpty) await prefs.remove(_archiveKey(digits));
  }

  /// Empties every account-scoped singleton in memory back to its blank/seed
  /// state — the half of a switch that disk cannot do, since the singletons
  /// are already loaded with the outgoing account's data.
  static void _resetAllSingletons() {
    // Chats go through hydrate with an empty snapshot, NOT reset() — reset
    // reloads the sample conversations, and a wipe that plants demo chats
    // in a release build would break the no-fake-data rule twice over.
    ChatStore.instance.hydrate(const {'chats': []});
    CallLog.instance.resetForTest();
    ChatLock.instance.resetForTest();
    FeedStore.instance.resetForTest();
    FollowStore.instance.resetForTest();
    FeedMuteStore.instance.resetForTest();
    FeedPrefs.instance.resetForTest();
    FeedDrafts.instance.resetForTest();
    CommunityStore.instance.resetForTest();
    ScoreStore.instance.resetForTest();
    StreakStore.instance.resetForTest();
    StorageStore.instance.resetForTest();
    CreatorSubStore.instance.resetForTest();
    CommunitySubStore.instance.resetForTest();
    AiAssistant.instance.resetForTest();
    AiMemory.instance.resetForTest();
    AiConsent.instance.resetForTest();
    AiPassStore.instance.resetForTest();
    IdentityVerification.instance.resetForTest();
    AccountEmail.instance.resetForTest();
    BackupService.instance.resetForTest();
    BackupPrefs.instance.resetForTest();
    CloudSync.instance.resetForTest();
    TwoStepVerification.instance.resetForTest();
    QuickReplies.instance.resetForTest();
    PasswordHistory.instance.reset();
    ChatFolders.instance.resetForTest();
    PendingServerInvites.instance.resetForTest();
    InboxTiers.instance.resetForTest();
    MessageSoundStore.instance.resetForTest();
    SavedForms.instance.reset();
    VehicleInspections.instance.reset();
    QrStyleStore.instance.resetForTest();
    NwcStore.instance.resetForTest();
    SidebarPrefs.instance.resetForTest();
    StickerStore.instance.resetForTest();
    NotesStore.instance.resetForTest();
    ContactsStore.instance.resetForTest();
    LiveShareStore.instance.resetForTest();
    PaymentSecurityStore.instance.resetForTest();
    BookmarkStore.instance.resetForTest();
    FavouritesStore.instance.resetForTest();
    SavedPlacesStore.instance.resetForTest();
    PublicFeedAlerts.instance.resetForTest();
    WatchHistory.instance.resetForTest();
    WeatherCitiesStore.instance.resetForTest();
    RecentSearches.instance.resetForTest();
    StatusStore.instance.resetForTest();
    Scheduler.instance.resetForTest();
    SecureKeyExchange.instance.resetForTest();
    DoubleRatchet.instance.resetForTest();
    SenderKeyStore.instance.resetForTest();
    IdentityRecovery.resetReadyForTest();
    AppState.resetForTest();
  }

  /// Reads every account-scoped singleton back from the on-disk (just-swapped)
  /// storage. The caller has already reset the singletons to blank, so a store
  /// the incoming account never wrote stays empty rather than the previous
  /// account's. Each read is isolated: one store failing to load must not
  /// strand the rest half-swapped. The auto-save listeners are NOT re-wired
  /// here (they live on the permanent singletons and outlast the swap).
  static Future<void> _loadAllFromDisk() async {
    Future<void> t(Future<void> Function() step) async {
      try {
        await step();
      } catch (_) {}
    }

    // Crypto first: the ratchet and sender chains a returning account reads
    // its chats with.
    await t(SecureKeyExchange.instance.load);
    await t(DoubleRatchet.instance.load);
    await t(SenderKeyStore.instance.load);
    await t(IdentityRecovery.load);
    // Settings, profile and conversations (no listener re-wiring).
    await t(Persistence.reload);
    // Every account-scoped store that reads from disk.
    await t(CallLog.instance.load);
    await t(ChatLock.instance.load);
    await t(FeedStore.instance.load);
    await t(FollowStore.instance.load);
    await t(FeedMuteStore.instance.load);
    await t(FeedPrefs.instance.load);
    await t(FeedDrafts.instance.load);
    await t(CommunityStore.instance.load);
    await t(ScoreStore.instance.load);
    await t(StreakStore.instance.load);
    await t(StorageStore.instance.load);
    await t(CreatorSubStore.instance.load);
    await t(CommunitySubStore.instance.load);
    await t(AiAssistant.instance.load);
    await t(AiMemory.instance.load);
    await t(AiConsent.instance.load);
    await t(AiPassStore.instance.load);
    await t(IdentityVerification.instance.load);
    await t(AccountEmail.instance.load);
    await t(BackupService.instance.load);
    // CloudSync is deliberately NOT reloaded here: its load() arms a debounce
    // timer and subscribes to the synced stores, and re-arming it mid-switch
    // would upload under a half-swapped state. It stays reset (off) until the
    // next app launch re-arms it from disk — exactly what a switch did before
    // this became archive-and-restore. Its account-scoped key material was
    // cleared by [_resetAllSingletons], so it holds nothing of either account.
    await t(TwoStepVerification.instance.load);
    await t(QuickReplies.instance.load);
    // Which passwords an account has already used is a fact about THAT
    // account, and the salt the digests are built on is per-account too — so
    // the next person on this phone starts with an empty history rather than
    // being refused a password somebody else once had.
    await t(PasswordHistory.instance.load);
    await t(ChatFolders.instance.load);
    await t(PendingServerInvites.instance.load);
    await t(InboxTiers.instance.load);
    await t(MessageSoundStore.instance.load);
    // A form is a list of questions this person keeps asking people — as
    // much a statement about them as a chat folder is. The next account on
    // this phone inherits none of it.
    await t(SavedForms.instance.load);
    // A vehicle, who drove it, when and where is a record of one
    // account's working day. The next account on this phone inherits
    // none of it, and its own comes back.
    await t(VehicleInspections.instance.load);
    await t(QrStyleStore.instance.load);
    // A connected Lightning wallet is ONE person's spending key. The next
    // account must never inherit it, and its own must come back.
    await t(NwcStore.instance.load);
    await t(SidebarPrefs.instance.load);
    await t(StickerStore.instance.load);
    await t(NotesStore.instance.load);
    await t(ContactsStore.instance.load);
    await t(LiveShareStore.instance.load);
    await t(PaymentSecurityStore.instance.load);
    await t(BookmarkStore.instance.load);
    await t(FavouritesStore.instance.load);
    await t(SavedPlacesStore.instance.load);
    // The like/reply counters for YOUR OWN public posts. Account-scoped
    // because the next account's posts are not this one's — and because a
    // stale counter would alert the wrong person about somebody else's post.
    await t(PublicFeedAlerts.instance.load);
    await t(WatchHistory.instance.load);
    await t(WeatherCitiesStore.instance.load);
    await t(RecentSearches.instance.load);
    await t(StatusStore.instance.load);
  }
}
