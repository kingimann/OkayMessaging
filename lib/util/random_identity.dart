import 'dart:math';

/// Friendly random identities for people who skip the naming step.
///
/// An account with no handle can be told to nobody, and a blank display
/// name used to fall back to the raw phone number — which is exactly the
/// thing a privacy app should not print at the top of a profile. So a
/// sign-up that leaves either field empty gets a generated one instead:
/// two wholesome words and a couple of digits, obviously not trying to
/// impersonate anyone, and changeable in the profile at any time.
class RandomIdentity {
  RandomIdentity._();

  static const List<String> _adjectives = [
    'sunny', 'swift', 'quiet', 'lucky', 'cosmic', 'gentle',
    'bright', 'mellow', 'brave', 'coral', 'amber', 'misty',
    'golden', 'breezy', 'velvet', 'silver', 'polar', 'maple',
    'ember', 'indigo', 'cedar', 'tidal', 'dusty', 'clover',
  ];

  static const List<String> _nouns = [
    'otter', 'falcon', 'willow', 'comet', 'harbor', 'meadow',
    'pebble', 'aspen', 'dolphin', 'lantern', 'juniper', 'sparrow',
    'glacier', 'prairie', 'heron', 'acorn', 'breeze', 'summit',
    'reef', 'moss', 'quill', 'drift', 'fern', 'brook',
  ];

  static final Random _rng = Random.secure();

  /// A valid, claimable handle: `swiftotter42`. Lowercase letters and two
  /// digits only, so it passes the same validation typed usernames do.
  static String username([Random? rng]) {
    final r = rng ?? _rng;
    return '${_adjectives[r.nextInt(_adjectives.length)]}'
        '${_nouns[r.nextInt(_nouns.length)]}'
        '${10 + r.nextInt(90)}';
  }

  /// A presentable display name from the same words: `Swift Otter`.
  static String displayName([Random? rng]) {
    final r = rng ?? _rng;
    String cap(String w) => w[0].toUpperCase() + w.substring(1);
    return '${cap(_adjectives[r.nextInt(_adjectives.length)])} '
        '${cap(_nouns[r.nextInt(_nouns.length)])}';
  }
}
