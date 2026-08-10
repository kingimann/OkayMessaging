/// One inbox, one account — the canonical form of an email address.
///
/// `you+1@gmail.com`, `you+2@gmail.com`, `y.o.u@gmail.com` and `you@gmail.com`
/// are the same mailbox. Every one of them can be verified, because every one
/// of them really arrives. So without this, a single Gmail account mints an
/// unlimited supply of "verified emails" — which is the same hole as a
/// disposable inbox wearing a respectable domain, and it defeats the same gate:
/// email is one third of what full verification means here.
///
/// [canonical] collapses those to one string, and that string is what gets
/// hashed for the taken-check. Two accounts can no longer stand on one inbox.
///
/// **Conservative on purpose, by a known-provider list.** Sub-addressing is a
/// convention, not a rule: a domain is free to treat `+` as an ordinary
/// character, and some do. Canonicalizing there would collapse two DIFFERENT
/// people's addresses into one and lock the second out of their own recovery
/// route — much worse than letting an alias through. So an unknown domain is
/// left exactly as written, and only providers documented to do sub-addressing
/// are folded. Dot-stripping is narrower still: Google alone ignores dots,
/// and elsewhere `j.smith@` and `jsmith@` are genuinely two people.
///
/// **A pre-existing wrinkle this widens slightly, stated rather than hidden.**
/// An address is claimed when it is SAVED, before it is confirmed, so somebody
/// can already reserve an address they cannot read and keep its owner off it.
/// Canonicalizing means a claim on `victim+x@gmail.com` now also holds
/// `victim@gmail.com`. The honest fix for both is to claim at verification
/// rather than at save; that is a change to the claim lifecycle and does not
/// belong bundled in here.
library;

class EmailIdentity {
  EmailIdentity._();

  /// Domains that treat everything after `+` in the local part as a tag on
  /// the same mailbox. Grown only by adding a provider that documents it.
  static const Set<String> _subAddressing = {
    'gmail.com', 'googlemail.com',
    'outlook.com', 'hotmail.com', 'live.com', 'msn.com',
    'icloud.com', 'me.com', 'mac.com',
    'proton.me', 'protonmail.com', 'protonmail.ch', 'pm.me',
    'fastmail.com', 'fastmail.fm',
    'zoho.com', 'zohomail.com',
    'gmx.com', 'gmx.net', 'gmx.de', 'gmx.at', 'gmx.ch', 'web.de',
    'yandex.com', 'yandex.ru',
    'aol.com',
    'tutanota.com', 'tutanota.de', 'tuta.com', 'tuta.io',
    'hey.com', 'mailbox.org', 'posteo.de', 'posteo.net', 'runbox.com',
    'hushmail.com', 'mail.com',
    // Deliberately NOT yahoo.com/ymail.com: Yahoo's disposable addresses use
    // a different separator and it does not do '+' sub-addressing, so
    // folding there would canonicalize an undeliverable address onto a real
    // person's.
  };

  /// Domains where a dot in the local part is ignored by the provider.
  /// Google and only Google — everywhere else `j.smith` is not `jsmith`.
  static const Set<String> _dotBlind = {'gmail.com', 'googlemail.com'};

  /// Domains that are the same mailbox under another name.
  static const Map<String, String> _aliases = {
    'googlemail.com': 'gmail.com',
  };

  /// The one string that identifies the MAILBOX behind [raw].
  ///
  /// Returns the trimmed, lowercased address unchanged when the domain is
  /// unknown or the address is malformed — never a guess.
  static String canonical(String raw) {
    final e = raw.trim().toLowerCase();
    final at = e.lastIndexOf('@');
    if (at <= 0 || at == e.length - 1) return e;
    var local = e.substring(0, at);
    var domain = e.substring(at + 1);
    while (domain.endsWith('.')) {
      domain = domain.substring(0, domain.length - 1);
    }
    if (domain.isEmpty) return e;

    if (_subAddressing.contains(domain)) {
      final plus = local.indexOf('+');
      // A local part that is ONLY a tag ('+tag@') is not an address whose
      // mailbox can be worked out, so it is left alone.
      if (plus > 0) local = local.substring(0, plus);
    }
    if (_dotBlind.contains(domain)) local = local.replaceAll('.', '');
    domain = _aliases[domain] ?? domain;
    if (local.isEmpty) return e;
    return '$local@$domain';
  }

  /// Whether [a] and [b] reach the same mailbox.
  static bool sameMailbox(String a, String b) => canonical(a) == canonical(b);
}
