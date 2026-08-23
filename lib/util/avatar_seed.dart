/// Turns the avatar seed STORED on a profile into the one actually drawn.
///
/// The "choose an avatar" shelf used to offer everybody the same eighteen
/// strings — `okay-<batch>-<i>` — so two people who both took the first
/// character genuinely ended up holding the same seed and drawing the same
/// face. That was reported three times as two contacts being indistinguishable
/// in the chat list and the call log, and it looked like a rendering fault. It
/// was not: the shelf is salted per account now (`okay-<salt>-<batch>-<i>`), so
/// no two people can be offered the same string again.
///
/// What that fix cannot do is repair a seed already chosen, because a contact's
/// `avatarSeed` only ever arrives from what THEY send — nothing on the reader's
/// device derives or heals it. This is that repair, done at DRAW time: a
/// pre-fix seed is re-salted with the person's own identity, so the face is
/// unique to them again.
///
/// **Consistent everywhere, which is the whole reason this is safe.** The salt
/// is the person's handle (or their phone digits), which every device that can
/// see them already agrees on — their own included, since [UserAvatar] draws a
/// profile the same way whether it is yours or somebody else's. So the
/// re-salted face is the same on every phone and in their own mirror, rather
/// than each device inventing its own.
///
/// The cost, stated rather than buried: anyone who picked an avatar before the
/// shelf was salted sees their character change, once. It is the price of the
/// two of them not being the same person on screen.
class AvatarSeed {
  const AvatarSeed._();

  /// A seed minted before the shelf was salted. Post-fix seeds carry the
  /// account's own salt and so have one more segment; anything not minted by
  /// this app's shelf is left alone.
  static bool isLegacy(String seed) =>
      seed.startsWith('okay-') && seed.split('-').length == 3;

  /// The seed to hand the renderer. Unchanged for a post-fix seed, and for a
  /// person this device can name in no stable way at all — inventing a salt
  /// from nothing would draw a different face on every device, which is worse
  /// than the duplicate this exists to fix.
  ///
  /// **For drawing only.** The result must never be stored on a profile or put
  /// on the wire: the stored seed stays exactly as its owner chose it, so this
  /// stays a repair the reader applies rather than a rewrite of somebody's
  /// profile behind their back.
  static String drawn(String seed, {String username = '', String phone = ''}) {
    if (!isLegacy(seed)) return seed;
    // The handle first — stable, and what the person thinks of as their
    // identity — then the phone's DIGITS, normalised because the same number
    // is written several ways across this app ('+1 555 0100' and '+15550100'
    // are one person, and a salt that told them apart would draw two faces).
    final handle = username.trim().toLowerCase();
    final key = handle.isNotEmpty ? handle : phone.replaceAll(RegExp(r'\D'), '');
    if (key.isEmpty) return seed;
    return '$seed-$_legacyTag${_stableHash(key)}';
  }

  static const String _legacyTag = 'p';

  /// What makes an account's "choose an avatar" shelf its own, so two people
  /// can never be offered the same eighteen strings again.
  ///
  /// PUBLIC, and it uses [_stableHash] for the same reason everything else
  /// here does. The shelf used to salt itself with Dart's built-in string
  /// hash, which is an implementation detail free to differ between the VM
  /// and dart2js — so the screen's own promise ("the same eighteen every
  /// time, so somebody can go away and come back for the one they liked")
  /// did not hold across platforms.
  /// The illustrated avatar an account starts with, off its OWN shelf.
  ///
  /// **Why a default exists at all.** Nothing ever assigned one: a new
  /// account got a derived colour and no `emoji`, `avatarSeed`, `avatarFace`
  /// or `avatarGif`, so [UserAvatar] fell all the way through to letter
  /// initials. Reported as "on the account for Apple it doesn't show profile
  /// pictures" — and on a fresh account that was true of everything on
  /// screen, because the account had no picture and every other person was a
  /// stranger.
  ///
  /// **It is generated, not invented.** This is the app's own identicon —
  /// the same class of thing as the coloured initial it replaces, derived
  /// deterministically from the account's own key — so it claims nothing
  /// about the person and never stands in for a real photograph. The
  /// no-fake-data rule is about inventing PEOPLE and activity; a character
  /// drawn from your own handle is decoration, exactly as the colour already
  /// was.
  ///
  /// **The FIRST of the eighteen this account is offered**, so the default is
  /// already on their shelf rather than an unreachable nineteenth — somebody
  /// changing it is picking a neighbour, not hunting for what they started
  /// with.
  static String defaultFor(String key) => 'okay-${shelfSalt(key)}-0-0';

  static String shelfSalt(String key) {
    final k = key.trim();
    return k.isEmpty ? '0' : '${_stableHash(k) % 100000}';
  }

  /// Deliberately NOT Dart's own built-in string hash: that is an
  /// implementation detail and is free to differ between the VM and dart2js,
  /// which would draw one face on the phone and another on the web build for
  /// the same person. This one is plain arithmetic, so every platform agrees —
  /// and it stays well inside 2^53, so JavaScript's doubles lose nothing.
  /// (A test bans the built-in by name from this file; the guard errs safe, so
  /// do not write the identifier here even in a comment.)
  static int _stableHash(String value) {
    var h = 0;
    for (final unit in value.codeUnits) {
      h = (h * 31 + unit) % 1000000007;
    }
    return h;
  }
}
