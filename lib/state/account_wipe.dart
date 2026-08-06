// The stores' resetForTest() methods are exactly "drop every trace of this
// account from memory", which is what an account switch needs and the one
// production event that legitimately does. Duplicating twenty-five
// clear-for-switch methods would drift the first time a store changed;
// reusing the resets cannot.
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'package:shared_preferences/shared_preferences.dart';

import '../app_state.dart';
import '../crypto/double_ratchet.dart';
import '../crypto/identity_recovery.dart';
import '../crypto/key_exchange.dart';
import '../crypto/sender_key.dart';
import 'secure_store.dart';
import 'account_email.dart';
import 'backup_service.dart';
import 'bookmark_store.dart';
import 'call_log.dart';
import 'chat_lock.dart';
import 'chat_store.dart';
import 'cloud_sync.dart';
import 'ai_assistant.dart';
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
import 'notes_store.dart';
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

/// Erases the previous account when a DIFFERENT account signs in on this
/// device.
///
/// Every store here is device-scoped, which is right while one account owns
/// the device and catastrophic the moment a second one signs in: a fresh
/// account inherited the last one's chats, verification badge, score, feed —
/// everything. Signing back into the SAME account keeps its data (that is
/// the "chats stay on the device" promise); it is the switch that wipes.
///
/// The mechanism is a keep-list, not a wipe-list, on purpose: preferences
/// that describe the device or the person holding it survive, and EVERYTHING
/// else goes — so a store added next month is wiped by default instead of
/// leaking by default. The crypto state goes too: the ratchet sessions and
/// sender-key chains belong to the old identity, and keeping the identity
/// keypair would let peers correlate two accounts as one device.
class AccountWipe {
  AccountWipe._();

  /// What survives a switch: the device's own settings, the terms the HUMAN
  /// accepted, and the welcome-back card for the account that left.
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
  };

  /// Where the digits of the current owner live, so the next sign-in can
  /// tell "same account returning" from "different account arriving".
  static const ownerKey = 'owner_digits_v1';

  static String _digits(String phone) => phone.replaceAll(RegExp(r'\D'), '');

  /// Wipes if [nextPhone] is not the account the device currently belongs
  /// to, and records the new owner either way. Call BEFORE persisting the
  /// new identity.
  static Future<void> onSignIn(String nextPhone) async {
    final prefs = await SharedPreferences.getInstance();
    final previous = prefs.getString(ownerKey) ?? '';
    final next = _digits(nextPhone);
    if (previous.isNotEmpty && previous != next) {
      await _wipe(prefs);
    }
    await prefs.setString(ownerKey, next);
  }

  /// Complete local erasure, for **Delete account**: unlike a switch there
  /// is no next sign-in to serve, so the keep-list goes too — device PIN,
  /// accepted terms, welcome-back card, owner marker, everything.
  static Future<void> eraseEverything() async {
    final prefs = await SharedPreferences.getInstance();
    await _wipe(prefs); // resets every store and the keychain
    await prefs.clear(); // then the keep-list _wipe restored
  }

  static Future<void> _wipe(SharedPreferences prefs) async {
    // Disk first: keep-list snapshot, clear, restore.
    final kept = <String, Object>{};
    for (final key in keepKeys) {
      final v = prefs.get(key);
      if (v != null) kept[key] = v;
    }
    await prefs.clear();
    for (final e in kept.entries) {
      final v = e.value;
      if (v is String) await prefs.setString(e.key, v);
      if (v is bool) await prefs.setBool(e.key, v);
      if (v is int) await prefs.setInt(e.key, v);
      if (v is double) await prefs.setDouble(e.key, v);
    }

    // Then memory: the singletons are already loaded with the old account's
    // data and would write it straight back over the cleared keys.
    //
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
    AiPassStore.instance.resetForTest();
    IdentityVerification.instance.resetForTest();
    AccountEmail.instance.resetForTest();
    BackupService.instance.resetForTest();
    CloudSync.instance.resetForTest();
    TwoStepVerification.instance.resetForTest();
    QuickReplies.instance.resetForTest();
    SidebarPrefs.instance.resetForTest();
    StickerStore.instance.resetForTest();
    NotesStore.instance.resetForTest();
    BookmarkStore.instance.resetForTest();
    FavouritesStore.instance.resetForTest();
    SavedPlacesStore.instance.resetForTest();
    RecentSearches.instance.resetForTest();
    StatusStore.instance.resetForTest();
    Scheduler.instance.resetForTest();
    SecureKeyExchange.instance.resetForTest();
    DoubleRatchet.instance.resetForTest();
    SenderKeyStore.instance.resetForTest();
    IdentityRecovery.resetReadyForTest();
    AppState.resetForTest();

    // The keychain too: prefs.clear() no longer reaches the key material
    // now that it lives where backups can't. The identity keypair, ratchet
    // sessions and sender chains all belong to the account that left —
    // keeping the keypair would let peers correlate two accounts as one
    // device, and iOS keychains survive even a reinstall.
    await SecureStore.instance.delete('device_ec_priv');
    await SecureStore.instance.delete('double_ratchet');
    await SecureStore.instance.delete('sender_keys');
  }
}
