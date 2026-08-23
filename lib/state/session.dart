import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supa;

import '../app_state.dart';
import '../relay/relay_config.dart';
import '../relay/relay_service.dart';
import '../util/avatar_seed.dart';
import '../util/person_color.dart';
import '../util/account_code.dart';
import '../models/user.dart';
import 'account_service.dart';
import 'abuse_guard.dart';
import 'account_wipe.dart';
import '../crypto/identity_recovery.dart';
import 'numberless_grace.dart';
import 'voice_presence_store.dart';
import 'push_service.dart';

/// The signed-in identity, keyed by phone number and stored **only on this
/// device**. There is no server: signing in just records who you are locally
/// so the app can show your profile and stamp your messages.
class Session {
  Session._();
  static final Session instance = Session._();

  static const _key = 'session_v1';

  /// The current signed-in user, or null when signed out.
  final ValueNotifier<AppUser?> user = ValueNotifier<AppUser?>(null);

  bool get isSignedIn => user.value != null;

  SharedPreferences? _prefs;

  /// Loads any saved identity from device storage at startup.
  Future<void> load() async {
    _prefs ??= await SharedPreferences.getInstance();
    final raw = _prefs!.getString(_key);
    if (raw != null) {
      try {
        final json = jsonDecode(raw) as Map<String, dynamic>;
        var saved = AppUser.fromJson(json);
        // An account already signed in when this shipped would otherwise
        // stay a letterbox until it next signed IN — and on iOS the process
        // outlives days of resumes, so that could be a long time. The same
        // gap-fill as the sign-in path, applied to what came off disk.
        //
        // Rebuilt through the model's own round trip rather than a copyWith
        // AppUser does not have: one field changes, everything else is
        // whatever fromJson already read.
        final seed = _seedOrDefault(saved, saved.phone, saved.username.trim());
        if (seed != saved.avatarSeed) {
          json['avatarSeed'] = seed;
          saved = AppUser.fromJson(json);
          // Written back, or the default is recomputed on every launch and a
          // later change to the shelf salt would silently move somebody's
          // face. Once assigned, it is theirs.
          await _prefs!.setString(_key, jsonEncode(saved.toJson()));
        }
        user.value = saved;
        AppState.profile.value = saved;
      } catch (_) {}
    }
    final rawLast = _prefs!.getString(_kLast);
    if (rawLast != null) {
      try {
        lastAccount =
            AppUser.fromJson(jsonDecode(rawLast) as Map<String, dynamic>);
      } catch (_) {}
    }
    final rawChanged = _prefs!.getString(_kUsernameChangedAt);
    if (rawChanged != null) {
      _usernameChangedAt = DateTime.tryParse(rawChanged);
    }
    final rawIdentity = _prefs!.getString(_kIdentityChangedAt);
    if (rawIdentity != null) {
      _identityChangedAt = DateTime.tryParse(rawIdentity);
    }
    _identityChangedFor = _prefs!.getString(_kIdentityChangedFor) ?? '';
    final rawKnown = _prefs!.getString(_kKnown);
    if (rawKnown != null) {
      try {
        knownAccounts = [
          for (final e in jsonDecode(rawKnown) as List)
            AppUser.fromJson(Map<String, dynamic>.from(e as Map))
        ];
      } catch (_) {}
    }
    // Upgrades from before the list: the single remembered account seeds it.
    if (knownAccounts.isEmpty && lastAccount != null) {
      await rememberAccount(lastAccount!);
    }
    // Builds from before the account wipe never recorded who the device's
    // data belongs to. Stamp it from whoever is (or was last) signed in, or
    // the FIRST sign-in on an upgraded install finds no owner on record,
    // skips the wipe, and inherits everything — the exact bug the wipe
    // exists to stop, surviving one build longer through the upgrade.
    final owner = user.value ?? lastAccount;
    if (owner != null && !_prefs!.containsKey(AccountWipe.ownerKey)) {
      await _prefs!.setString(
          AccountWipe.ownerKey, owner.phone.replaceAll(RegExp(r'\D'), ''));
    }
  }

  /// Signs in with a phone number, display name, and optional username,
  /// persisting locally.
  /// The account's own avatar seed, or the default off its shelf when it has
  /// no avatar at all.
  ///
  /// Checks every avatar KIND, not just the seed: somebody with an emoji, a
  /// built face or a GIF already has a picture, and handing them a character
  /// underneath it would be assigning something they never asked for. Keyed
  /// on the handle where there is one and the number otherwise — the same key
  /// the shelf itself salts with, so the default really is the first of the
  /// eighteen this account is offered.
  @visibleForTesting
  static String debugSeedOrDefault(AppUser? prior, String phone, String handle) =>
      _seedOrDefault(prior, phone, handle);

  static String _seedOrDefault(AppUser? prior, String phone, String handle) {
    final existing = prior?.avatarSeed ?? '';
    if (existing.isNotEmpty) return existing;
    final hasOther = (prior?.avatarFace ?? '').isNotEmpty ||
        (prior?.avatarGif ?? '').isNotEmpty ||
        (prior?.emoji ?? '').isNotEmpty;
    if (hasOther) return '';
    final key = handle.isNotEmpty
        ? handle
        : (prior?.username.trim().isNotEmpty == true
            ? prior!.username.trim()
            : phone);
    return AvatarSeed.defaultFor(key);
  }

  Future<void> signIn({
    required String phone,
    required String name,
    String username = '',
    bool isSignup = false,
  }) async {
    // A DIFFERENT account signing in must not inherit this device's data —
    // chats, the verification badge, the score, any of it. Same account
    // returning keeps everything; that is the difference between signing
    // back in and switching.
    await AccountWipe.onSignIn(phone);
    // "Keeps everything" includes the PROFILE: this used to rebuild a bare
    // one — the bio, the avatar look, pronouns, link and
    // location gone — on every sign-back-in, while the comment above
    // promised otherwise. The remembered identity for the same digits is
    // the base; what was typed on the form only overrides what it names.
    final d = phone.replaceAll(RegExp(r'\D'), '');
    _prefs ??= await SharedPreferences.getInstance();
    AppUser? prior;
    // The base profile, best source first, so a rebuild keeps everything the
    // account had — about, pronouns, links, business and subscription fields —
    // instead of resetting to defaults or a stale copy.
    //
    // 1. The live in-memory profile: [AccountWipe.onSignIn] has just reloaded
    //    it from the returning account's restored disk (and on a same-account
    //    sign-back-in it never left memory), so it is the most CURRENT — later
    //    profile edits included, which the remembered list never saw.
    // 2. The saved session blob, if still on disk.
    // 3. The remembered-accounts list (identity as of the last sign-in).
    bool matches(String p) => p.replaceAll(RegExp(r'\D'), '') == d;
    final live = AppState.profile.value;
    if (matches(live.phone)) prior = live;
    if (prior == null) {
      final restoredRaw = _prefs!.getString(_key);
      if (restoredRaw != null) {
        try {
          final u =
              AppUser.fromJson(jsonDecode(restoredRaw) as Map<String, dynamic>);
          if (matches(u.phone)) prior = u;
        } catch (_) {}
      }
    }
    for (final a in [
      if (lastAccount != null) lastAccount!,
      ...knownAccounts,
    ]) {
      if (prior != null) break;
      if (matches(a.phone)) prior = a;
    }
    final trimmedName = name.trim().isEmpty
        ? (prior?.name ?? phone)
        : name.trim();
    final handle = _normalizeUsername(username);
    final me = AppUser(
      id: phone,
      name: trimmedName,
      avatarColor: prior?.avatarColor ?? colorForPhone(phone),
      about: prior?.about ?? '',
      phone: phone,
      username: handle.isNotEmpty ? handle : (prior?.username ?? ''),
      verified: prior?.verified ?? false,
      score: prior?.score ?? 0,
      emoji: prior?.emoji ?? '',
      // An account with NO avatar of any kind starts with an illustrated one
      // off its own shelf, rather than falling through to letter initials.
      // Nothing ever assigned one, so every new account — and every account
      // that never went looking in Edit profile — was a letterbox.
      //
      // Only ever fills a GAP: any avatar the account already has (a picked
      // character, a built face, a GIF, an emoji) is left exactly alone, so
      // nobody loses something they chose. It is on their own shelf, so
      // changing it is picking a neighbour.
      avatarSeed: _seedOrDefault(prior, phone, handle),
      avatarFace: prior?.avatarFace ?? '',
      avatarGif: prior?.avatarGif ?? '',
      pronouns: prior?.pronouns ?? '',
      link: prior?.link ?? '',
      avatarColor2: prior?.avatarColor2 ?? '',
      bannerColor: prior?.bannerColor ?? '',
      location: prior?.location ?? '',
      isBusiness: prior?.isBusiness ?? false,
      businessCategory: prior?.businessCategory ?? '',
      businessHours: prior?.businessHours ?? '',
      subscribable: prior?.subscribable ?? false,
      subscriptionTier: prior?.subscriptionTier ?? 0,
      subscriptionPitch: prior?.subscriptionPitch ?? '',
      subscriptionTiersJson: prior?.subscriptionTiersJson ?? '',
      lightningAddress: prior?.lightningAddress ?? '',
      // Stamped ONCE, on the first sign-in this device knows of for this
      // account, and carried by every rebuild after — signing in again
      // must not reset the day somebody joined.
      joinedAt: prior?.joinedAt ?? DateTime.now(),
    );
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setString(_key, jsonEncode(me.toJson()));
    user.value = me;
    AppState.profile.value = me;
    // Remembered NOW rather than only at sign-out, so a crash or reinstall
    // that skips sign-out still offers this profile next time. (The wipe
    // keeps the list: it is device history, like last_account_v1.)
    await rememberAccount(me);
    // Attach this device's push token to the account that now owns it (and
    // release any previous account's claim on it, server-side).
    if (RelayConfig.isEnabled) {
      try {
        await PushService.instance.reupload();
      } catch (_) {}
      // Mark the account seen at sign-in, so the moderation roster shows it
      // online right away (docs/admin_users.sql). Numberless: no-op.
      AccountService.instance.touchLastSeen();
      // Reactivation IS the sign-in: a deactivated account's directory row
      // is hidden (docs/account_lifecycle.sql), and coming back has to
      // clear that or "temporarily" was a lie. Own-row RLS; best-effort —
      // a project without the column just answers with an error.
      if (!AccountCode.isCode(phone)) {
        try {
          await supa.Supabase.instance.client.from('usernames').update({
            'hidden': false,
          }).eq('phone', phone.replaceAll(RegExp(r'\D'), ''));
        } catch (_) {}
      }
    }
    // New-device flag: an account arriving on a device it has never signed in
    // on before (and not its own fresh signup) is exactly how a stolen or
    // shared credential shows up — so tell the user. Local detection; a true
    // cross-device alert to the account's OTHER devices is a server follow-up.
    final newDevice =
        await AbuseGuard.instance.registerSignIn(d, isSignup: isSignup);
    if (newDevice) {
      PushService.instance.localNotify(
        title: 'New device sign-in',
        body: 'Your account just signed in on this device. If this wasn\'t '
            'you, secure your account.',
      );
    }
  }

  /// Signs in with no phone number at all.
  ///
  /// For anyone who does not want to hand over a number, and for the ordinary
  /// case of putting the app on a second device to try it. What they get
  /// instead is an [AccountCode] — a digit string that cannot be mistaken for
  /// a real number — which is what the relay listens on and what the mesh
  /// addresses, so everything downstream works unchanged.
  ///
  /// The consequence, said rather than discovered: nobody can find you from
  /// their contacts, because there is no number of yours in anybody's phone.
  /// They reach you by your code or your username, and that is all. It also
  /// means no Supabase session — Supabase authenticates a phone — so every
  /// server-backed part of the app is locked behind [PhoneGate]. Chat is not
  /// one of them: broadcast and the mailbox are both reachable with the anon
  /// key, so messages work exactly as they do for anybody else.
  ///
  /// [name] may be empty, and usually is: signing up this way is one field.
  /// The username stands in for it rather than the account code, which is a
  /// display name nobody would choose and nobody would recognise.
  Future<void> signInWithoutNumber({
    String name = '',
    required String username,
    String? code,
    bool isSignup = false,
  }) {
    final handle = _normalizeUsername(username);
    return signIn(
      // Callers that claimed the handle in the directory pass the code they
      // claimed it under; minting a fresh one here would orphan that claim.
      phone: code ?? AccountCode.mint(),
      name: name.trim().isEmpty ? handle : name.trim(),
      username: handle,
      isSignup: isSignup,
    );
  }

  /// Whether the signed-in account has no phone number behind it.
  bool get isNumberless {
    final phone = user.value?.phone ?? '';
    return phone.isNotEmpty && AccountCode.isCode(phone);
  }

  // --- Verify a name-only account IN PLACE -------------------------------
  //
  // A name-only account isn't locked out on a clock — it can use the app,
  // held to tighter anti-spam limits (see AbuseGuard) until it verifies a
  // number. Verifying lifts those limits AND unlocks the server-session
  // features, and it does so WITHOUT losing the account: this upgrades in
  // place, keeping every bit of on-device data.

  /// Attaches a verified [phone] to the CURRENT name-only account IN PLACE —
  /// the "verify to keep your account" path. The on-device data (chats,
  /// servers, notes, everything) is untouched: the owner marker is moved to the
  /// new digits first, so nothing reads this as an account switch, then the
  /// profile's identity is re-pointed from the account code to the number, with
  /// every other profile field carried over. The Supabase session the number
  /// unlocks is established by the caller's verification before this runs.
  Future<bool> attachNumberInPlace(String phone, {String username = ''}) async {
    final current = user.value;
    if (current == null) return false;
    final newDigits = phone.replaceAll(RegExp(r'\D'), '');
    if (newDigits.isEmpty) return false;
    // Refused while the clock runs — with two exemptions, both for things
    // that are not a change of address at all.
    //
    // 1. A real phone number landing on an account that has none. It is the
    //    strongest identity the app has, and pushing people toward it must
    //    not be something a cooldown can block.
    // 2. Re-attaching the SAME identity. `email-account` answers a
    //    re-verification with the code it already stamped, so this is the
    //    ordinary "verify again" path, and refusing it would report a
    //    cooldown to somebody who is not changing anything.
    final sameIdentity = current.phone.replaceAll(RegExp(r'\D'), '') == newDigits;
    final isRealNumber = !AccountCode.isCode(phone);
    final wouldBeAnUpgrade = isRealNumber && isNumberless;
    if (!sameIdentity &&
        !wouldBeAnUpgrade &&
        identityCooldownLeft() > Duration.zero) {
      return false;
    }
    _prefs ??= await SharedPreferences.getInstance();
    // The 14-day clock stops here, for good: the account has a number now,
    // so it is no longer the unclaimed kind that expires.
    await NumberlessGrace.instance.clear(current.phone);
    // Same account, not a switch: park/clear nothing, keep all the data.
    await _prefs!.setString(AccountWipe.ownerKey, newDigits);
    final handle =
        username.trim().isEmpty ? current.username : _normalizeUsername(username);
    final upgraded = AppUser(
      id: phone,
      name: current.name,
      avatarColor: current.avatarColor,
      about: current.about,
      phone: phone,
      username: handle,
      verified: current.verified,
      score: current.score,
      emoji: current.emoji,
      avatarSeed: current.avatarSeed,
      avatarFace: current.avatarFace,
      avatarGif: current.avatarGif,
      pronouns: current.pronouns,
      link: current.link,
      avatarColor2: current.avatarColor2,
      bannerColor: current.bannerColor,
      location: current.location,
      isBusiness: current.isBusiness,
      businessCategory: current.businessCategory,
      businessHours: current.businessHours,
      subscribable: current.subscribable,
      subscriptionTier: current.subscriptionTier,
      subscriptionPitch: current.subscriptionPitch,
      subscriptionTiersJson: current.subscriptionTiersJson,
      lightningAddress: current.lightningAddress,
      joinedAt: current.joinedAt,
    );
    await _prefs!.setString(_key, jsonEncode(upgraded.toJson()));
    user.value = upgraded;
    AppState.profile.value = upgraded;
    await rememberAccount(upgraded);
    if (RelayConfig.isEnabled) {
      // THE DIRECTORY HAS TO MOVE WITH THE ACCOUNT. `usernames.phone` is what
      // every server-side handle lookup joins on — `public_follow`,
      // `public_follow_counts`, `public_followers`/`public_following`,
      // `creator-subscribe`'s handle→phone resolve — and each of them
      // RETURNS SILENTLY when it finds no row rather than raising. So an
      // upgraded account whose directory row still named its old address was
      // not half-broken but invisible: a follow it made was accepted by the
      // button, dropped by the server, and gone at the next sync. Reported
      // 2026-08-18 as "when Giti follows people it goes back to zero".
      //
      // Best-effort and unawaited-in-spirit: the local upgrade has already
      // taken, and a directory that cannot be reached right now is not a
      // reason to fail the sign-in.
      try {
        await AccountService.instance
            .claimUsername(phone, handle, name: current.name);
      } catch (_) {}
      try {
        await PushService.instance.reupload();
      } catch (_) {}
      AccountService.instance.touchLastSeen();
    }
    // Every attach that MOVES the address starts the clock, the free first one
    // included — otherwise the second could follow it the same afternoon. A
    // re-verification of the identity already held is not a change and does
    // not restart it.
    if (!sameIdentity) await _recordIdentityChange(newDigits);
    return true;
  }

  /// Lowercases and strips a leading '@' / invalid characters from a username.
  static String _normalizeUsername(String raw) => raw
      .trim()
      .replaceFirst(RegExp(r'^@+'), '')
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9_.]'), '');

  // --- Username change cooldown --------------------------------------------
  //
  // A handle is how other people find and refer to an account — somebody
  // who rotates theirs weekly breaks every "tell them @x" that is already
  // out in the world, and a fresh handle every few days is also how
  // impersonation and block-evasion look. So: changing an EXISTING handle
  // starts a 30-day cooldown. Setting one for the first time is free (the
  // sign-up mint counts as that), and the display NAME is never limited —
  // a name is presentation, a handle is identity.
  static const Duration usernameCooldown = Duration(days: 30);
  static const _kUsernameChangedAt = 'username_changed_at_v1';
  DateTime? _usernameChangedAt;

  /// How much longer the handle is locked, or [Duration.zero] when it may
  /// change now.
  Duration usernameCooldownLeft() {
    final at = _usernameChangedAt;
    if (at == null) return Duration.zero;
    final left = usernameCooldown - DateTime.now().difference(at);
    return left.isNegative ? Duration.zero : left;
  }

  /// The identity an account is ADDRESSED by — the phone number or the
  /// server-minted code an email earns — changes at most once every 30 days,
  /// for the same reason the handle does and more so: it is what every
  /// contact holds, what every message is delivered to, and what a ban is
  /// recorded against. An account cycling identities is what evasion looks
  /// like, and each change also asks every contact to learn a new address.
  ///
  /// The FIRST attach is free and always will be: that is the sign-up path
  /// (a name-only account earning a number or a verified email), and there is
  /// nothing to change from.
  static const Duration identityCooldown = Duration(days: 30);
  static const _kIdentityChangedAt = 'identity_changed_at_v1';
  static const _kIdentityChangedFor = 'identity_changed_for_v1';
  DateTime? _identityChangedAt;

  /// WHOSE clock it is, in digits. Without this the stamp is the DEVICE's, so
  /// one account changing its address would refuse the next account's very
  /// first verify on the same handset — a brand-new account being told it
  /// changed something recently. Caught by the suite: two tests that passed
  /// alone failed together, which is the same bug an hour apart on a real
  /// phone.
  String _identityChangedFor = '';

  /// How much longer the number/email identity is locked, or [Duration.zero]
  /// when it may change now — including for an account that is not the one
  /// the stamp belongs to.
  Duration identityCooldownLeft() {
    final at = _identityChangedAt;
    if (at == null) return Duration.zero;
    final me = (user.value?.phone ?? '').replaceAll(RegExp(r'\D'), '');
    if (me.isEmpty || me != _identityChangedFor) return Duration.zero;
    final left = identityCooldown - DateTime.now().difference(at);
    return left.isNegative ? Duration.zero : left;
  }

  /// The sentence every surface shows when [attachNumberInPlace] refuses, so
  /// the two verify screens cannot word the same rule differently. Null when
  /// nothing is locked.
  String? identityCooldownMessage() {
    final left = identityCooldownLeft();
    if (left == Duration.zero) return null;
    final days = (left.inHours / 24).ceil();
    return 'You changed the number or email on this account recently. You can '
        'change it again in $days ${days == 1 ? 'day' : 'days'}.';
  }

  /// Stamps the clock against the account it now belongs to — the NEW address,
  /// since that is who will be asking next time.
  Future<void> _recordIdentityChange(String digits) async {
    _identityChangedAt = DateTime.now();
    _identityChangedFor = digits;
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!
        .setString(_kIdentityChangedAt, _identityChangedAt!.toIso8601String());
    await _prefs!.setString(_kIdentityChangedFor, digits);
  }

  Future<void> _recordUsernameChange() async {
    _usernameChangedAt = DateTime.now();
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!
        .setString(_kUsernameChangedAt, _usernameChangedAt!.toIso8601String());
  }

  @visibleForTesting
  set debugUsernameChangedAt(DateTime? at) => _usernameChangedAt = at;

  @visibleForTesting
  set debugIdentityChangedAt(DateTime? at) {
    _identityChangedAt = at;
    // Stamped against whoever is signed in, or a test setting the clock would
    // be setting somebody else's and [identityCooldownLeft] would ignore it.
    _identityChangedFor = (user.value?.phone ?? '').replaceAll(RegExp(r'\D'), '');
  }

  /// Updates the signed-in user's name/about (and optionally username / avatar
  /// color) and persists it on the device, keeping the phone number (identity).
  Future<void> updateProfile({
    required String name,
    required String about,
    String? username,
    String? avatarColor,
    String? emoji,
    String? avatarSeed,
    String? avatarFace,
    String? avatarGif,
    String? pronouns,
    String? link,
    String? avatarColor2,
    String? bannerColor,
    String? location,
    bool? isBusiness,
    String? businessCategory,
    String? businessHours,
    bool? subscribable,
    int? subscriptionTier,
    String? subscriptionPitch,
    String? subscriptionTiersJson,
    String? lightningAddress,
  }) async {
    final current = user.value;
    if (current == null) return;
    // The handle changes at most once every [usernameCooldown]. MODIFYING
    // an existing one — including clearing it, or the clear-then-set
    // two-step would dodge the clock — is refused while the cooldown
    // runs (the edit screen disables the field and says why; this is the
    // belt under that). Names, and everything else, stay free.
    var nextUsername =
        username == null ? current.username : _normalizeUsername(username);
    if (nextUsername != current.username && current.username.isNotEmpty) {
      if (usernameCooldownLeft() > Duration.zero) {
        nextUsername = current.username;
      } else {
        await _recordUsernameChange();
      }
    }
    final updated = AppUser(
      id: current.id,
      name: name.trim().isEmpty ? current.name : name.trim(),
      avatarColor: (avatarColor == null || avatarColor.isEmpty)
          ? current.avatarColor
          : avatarColor,
      about: about.trim().isEmpty ? current.about : about.trim(),
      phone: current.phone,
      username: nextUsername,
      verified: current.verified,
      score: current.score,
      emoji: emoji ?? current.emoji,
      avatarSeed: avatarSeed ?? current.avatarSeed,
      avatarFace: avatarFace ?? current.avatarFace,
      avatarGif: avatarGif ?? current.avatarGif,
      pronouns: pronouns ?? current.pronouns,
      link: link ?? current.link,
      avatarColor2: avatarColor2 ?? current.avatarColor2,
      bannerColor: bannerColor ?? current.bannerColor,
      location: location ?? current.location,
      isBusiness: isBusiness ?? current.isBusiness,
      businessCategory: businessCategory ?? current.businessCategory,
      businessHours: businessHours ?? current.businessHours,
      subscribable: subscribable ?? current.subscribable,
      subscriptionTier: subscriptionTier ?? current.subscriptionTier,
      subscriptionPitch: subscriptionPitch ?? current.subscriptionPitch,
      subscriptionTiersJson:
          subscriptionTiersJson ?? current.subscriptionTiersJson,
      lightningAddress: lightningAddress ?? current.lightningAddress,
      joinedAt: current.joinedAt,
    );
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setString(_key, jsonEncode(updated.toJson()));
    user.value = updated;
    AppState.profile.value = updated;
  }

  /// Sets the verified (blue check) flag on the signed-in identity and
  /// persists it, mirroring the change into [AppState.profile].
  Future<void> setVerified(bool value) async {
    final current = user.value;
    if (current == null || current.verified == value) return;
    final updated = AppUser(
      id: current.id,
      name: current.name,
      avatarColor: current.avatarColor,
      about: current.about,
      phone: current.phone,
      username: current.username,
      isOnline: current.isOnline,
      isGroup: current.isGroup,
      verified: value,
      score: current.score,
      // Everything else rides along untouched — this rebuild used to drop
      // emoji, pronouns and link on the floor whenever the badge changed.
      emoji: current.emoji,
      avatarSeed: current.avatarSeed,
      avatarFace: current.avatarFace,
      avatarGif: current.avatarGif,
      pronouns: current.pronouns,
      link: current.link,
      avatarColor2: current.avatarColor2,
      bannerColor: current.bannerColor,
      location: current.location,
      isBusiness: current.isBusiness,
      businessCategory: current.businessCategory,
      businessHours: current.businessHours,
      subscribable: current.subscribable,
      subscriptionTier: current.subscriptionTier,
      subscriptionPitch: current.subscriptionPitch,
      subscriptionTiersJson: current.subscriptionTiersJson,
      lightningAddress: current.lightningAddress,
      joinedAt: current.joinedAt,
    );
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setString(_key, jsonEncode(updated.toJson()));
    user.value = updated;
    AppState.profile.value = updated;
  }

  static const _kLast = 'last_account_v1';
  static const _kKnown = 'known_accounts_v1';

  /// The identity that was signed in most recently — kept across sign-out so
  /// coming back is one tap, not a whole form.
  AppUser? lastAccount;

  /// Every account that has signed in on this device, most recent first —
  /// the login screen offers each as a one-tap way back in. Identity only
  /// (name, handle, number/code, avatar color): the account's DATA is wiped
  /// on switch as always; this remembers who, never what.
  List<AppUser> knownAccounts = [];

  static const _maxKnown = 5;

  /// Records [account] at the head of the remembered list, deduped by
  /// digits and capped. Called on both sign-in and sign-out, so a crash
  /// that skips sign-out still leaves the profile offered next time.
  Future<void> rememberAccount(AppUser account) async {
    final d = account.phone.replaceAll(RegExp(r'\D'), '');
    if (d.isEmpty) return;
    knownAccounts = [
      account,
      ...knownAccounts
          .where((a) => a.phone.replaceAll(RegExp(r'\D'), '') != d),
    ];
    if (knownAccounts.length > _maxKnown) {
      knownAccounts = knownAccounts.sublist(0, _maxKnown);
    }
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setString(
        _kKnown, jsonEncode([for (final a in knownAccounts) a.toJson()]));
  }

  /// Forgets every remembered profile, memory and disk — for **Delete
  /// account**: the erase clears the prefs file, but the in-memory list
  /// would re-persist the deleted identity with the next sign-in, offering
  /// one-tap entry into an account that no longer exists.
  Future<void> clearKnownAccounts() async {
    knownAccounts = [];
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.remove(_kKnown);
  }

  /// Drops one remembered profile (long-press → remove on the login list).
  Future<void> forgetAccount(String phone) async {
    final d = phone.replaceAll(RegExp(r'\D'), '');
    knownAccounts.removeWhere(
        (a) => a.phone.replaceAll(RegExp(r'\D'), '') == d);
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setString(
        _kKnown, jsonEncode([for (final a in knownAccounts) a.toJson()]));
    if (lastAccount != null &&
        lastAccount!.phone.replaceAll(RegExp(r'\D'), '') == d) {
      await clearLastAccount();
    }
  }

  /// Signs out and forgets the local identity (chats stay on the device).
  /// The account itself is remembered so signing back in is instant.
  ///
  /// **Unless it's a name-only account with no way back in at all.** A
  /// numberless account is NOT always unrecoverable — [IdentityRecovery]
  /// (`lib/widgets/recovery_gate.dart`) lets one set a recovery PIN, sealing
  /// its keys to the server under it, and `_numberlessPinSignIn`
  /// (`phone_login_screen.dart`) already signs one back in with that PIN —
  /// so erasing every numberless sign-out unconditionally would destroy
  /// accounts that genuinely can come back, and contradict "Deactivate
  /// temporarily"'s own numberless copy, which already promises exactly that
  /// PIN-based return. [IdentityRecovery.ready] is this device's own record
  /// of whether that backup was ever actually stored (only set true after
  /// the server confirms the write — see `createPinBackup`), so it's the
  /// right, honest signal for whether THIS sign-out is really the end of the
  /// road. Only when it's false — no backup was ever made, so there is
  /// really nothing to sign back in with, same situation the 14-day
  /// numberless-expiry clock (`enforceNumberlessGrace`) already erases for —
  /// does this mirror [AccountWipe.eraseCurrentAccount]'s erase-and-forget
  /// sequence instead of the normal remember-for-next-time path below.
  Future<void> signOut() async {
    _prefs ??= await SharedPreferences.getInstance();
    final current = user.value;
    if (current != null && isNumberless && !IdentityRecovery.ready.value) {
      await AccountWipe.eraseCurrentAccount();
      await NumberlessGrace.instance.clear(current.phone);
    } else if (current != null) {
      lastAccount = current;
      await _prefs!.setString(_kLast, jsonEncode(current.toJson()));
      await rememberAccount(current);
      // Belt and braces for the upgrade path: whoever is leaving owns the
      // data they leave behind, so the next sign-in can tell whether it is
      // them coming back.
      await _prefs!.setString(AccountWipe.ownerKey,
          current.phone.replaceAll(RegExp(r'\D'), ''));
    }
    await _prefs!.remove(_key);
    user.value = null;
    // And the LIVE profile with it. `user` was cleared here and
    // `AppState.profile` was not, so between signing out and the next
    // sign-in landing, the app's current profile was still the person who
    // just left — their name, their handle, their face. Every sign-in path
    // ends by setting it, so nothing needs the stale copy; what needed it
    // gone is everything in between, which on the numberless route is a
    // whole PIN dialog and a key adoption. It is also what the profile's
    // own auto-save listener would write to disk if anything nudged it
    // while the next account's slot was already restored.
    AppState.profile.value = const AppUser(
        id: '', name: '', avatarColor: '', phone: '', username: '');
    // The SERVER session belongs to the account that just left, and keeping
    // it around is why the next sign-in demanded the PREVIOUS account's
    // second factor: the auth client was still that person. Token first
    // (deleting it needs the session), then the subscriptions, then the
    // session itself. All best-effort — sign-out must never block on the
    // network, and in a build with no relay there is nothing to clear.
    // Announced while the relay is still up: an account that signs out
    // mid-voice must not keep sitting in the room under its old identity
    // until the heartbeat ages it out.
    try {
      VoicePresenceStore.instance.leave();
    } catch (_) {}
    if (RelayConfig.isEnabled) {
      try {
        await PushService.instance.removeToken();
      } catch (_) {}
      try {
        await RelayService.instance.stop();
      } catch (_) {}
      try {
        await supa.Supabase.instance.client.auth.signOut();
      } catch (_) {}
    }
  }

  /// Forgets the remembered account (Settings → sign-in screen → "Use a
  /// different account" keeps it; this is the hard erase).
  Future<void> clearLastAccount() async {
    lastAccount = null;
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.remove(_kLast);
  }

  /// Establishes a signed-in identity synchronously for tests.
  @visibleForTesting
  void signInForTest({
    String phone = '+1 555 0100',
    String name = 'You',
    String username = 'you',
  }) {
    final me = AppUser(
      id: phone,
      name: name,
      avatarColor: colorForPhone(phone),
      about: '',
      phone: phone,
      username: username,
    );
    user.value = me;
    AppState.profile.value = me;
  }

  @visibleForTesting
  void resetForTest() {
    user.value = null;
  }

  /// Deterministic avatar colour for a phone number (shared with the server
  /// directory so a person looks the same everywhere).
  /// Delegates to [personColorFor], which lives in `lib/util/` so stores that
  /// cannot import this file (the relay imports the chat store, and this
  /// imports the relay) can derive a per-person colour instead of falling
  /// back to one shared constant.
  static String colorForPhone(String phone) => personColorFor(phone);
}
