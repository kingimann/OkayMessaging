import 'package:flutter/foundation.dart';

import '../models/user.dart';
import 'account_service.dart';

/// Public profiles this device has looked up, kept for the app run.
///
/// **What it exists for.** Everywhere in this app a person is drawn by
/// `UserAvatar` with the colour they picked and the face they built — but
/// [knownUserFor] could only ever resolve YOURSELF or somebody there is
/// already a chat with. That is precisely the person you are NOT looking at
/// when you are trying to find somebody new, so a stranger drew as coloured
/// initials on their own profile and in every search result.
/// `docs/public_profiles.sql` publishes the real thing; this is what holds
/// the answer once it arrives.
///
/// **In memory only, deliberately, and never persisted.** These are other
/// people's public profiles: cheap to re-fetch, wrong to keep on disk (a
/// stale avatar outliving a change), and the one thing keeping this out of
/// `account_wipe`'s reckoning — nothing here can leak to the next account,
/// because nothing here survives the process. Same standing as
/// `GroupPresenceStore`.
///
/// **One lookup per handle per run.** [_asked] records the ask rather than
/// the answer, so a handle with no profile — a stranger who never saved one,
/// a project that has not run the migration — is not re-fetched on every
/// rebuild of every card that mentions them.
class DirectoryCache extends ChangeNotifier {
  DirectoryCache._();
  static final DirectoryCache instance = DirectoryCache._();

  final Map<String, AppUser> _byHandle = {};
  final Set<String> _asked = {};

  /// The published profile for [username], or null when nothing has arrived.
  ///
  /// Synchronous on purpose: it is read from `build`, and a future there is
  /// how a timeline ends up firing a request per card.
  AppUser? get(String username) {
    final handle = username.trim().toLowerCase().replaceFirst('@', '');
    return handle.isEmpty ? null : _byHandle[handle];
  }

  /// Fetches [username]'s public profile once, then notifies.
  ///
  /// Called from a screen that is genuinely showing ONE person — a profile
  /// being opened — never from a list row. A timeline fanning out a lookup
  /// per card is the exact shape `CommunityNoteInline` already refuses.
  Future<void> warm(String username) async {
    final handle = username.trim().toLowerCase().replaceFirst('@', '');
    if (handle.isEmpty || _asked.contains(handle)) return;
    _asked.add(handle);
    final user = await AccountService.instance.publicProfile(handle);
    if (user == null) return;
    _byHandle[handle] = user;
    notifyListeners();
  }

  @visibleForTesting
  void debugPut(String username, AppUser user) {
    _byHandle[username.trim().toLowerCase()] = user;
    _asked.add(username.trim().toLowerCase());
    notifyListeners();
  }

  @visibleForTesting
  void resetForTest() {
    _byHandle.clear();
    _asked.clear();
  }
}
