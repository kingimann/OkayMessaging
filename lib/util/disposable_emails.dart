/// Throwaway email domains — the ones that make an email address worthless as
/// a piece of accountability.
///
/// An email matters here because it is one third of [AccountVerification]:
/// phone, email and ID together are what community notes demand before
/// somebody may fact-check a stranger's post. A ten-minute public mailbox
/// satisfies that leg for free and infinitely, which turns the strongest gate
/// in the app into a formality.
///
/// **The line this draws, and it is deliberate: ephemeral public inbox = no,
/// forwarding alias = yes.** A privacy-first messenger must not punish somebody
/// for refusing to hand over their real address. Apple's Hide My Email
/// (`privaterelay.appleid.com`), SimpleLogin, addy.io, Firefox Relay and
/// DuckDuckGo's Duck Addresses are all deliberately ABSENT from the list below:
/// they are durable, they belong to one identifiable person, they can be
/// revoked by that person, and mail sent to them reaches a real human. Blocking
/// them would also break Sign in with Apple. What is refused is the other
/// thing entirely — a mailbox with no owner, often readable by anyone who
/// guesses the name, that stops existing in ten minutes.
///
/// **Honest limit.** A hardcoded list goes stale; new throwaway domains appear
/// every week and this one only updates on a build. It is the cheap floor that
/// catches the traffic, not a wall — the owner-updatable server list
/// (`ban_email`, docs/banned_signups.sql) is what handles a domain that shows
/// up tomorrow, and a determined person will always find one that is not here.
/// That is the same posture as `VoipNumbers`: a real first gate, honestly
/// described.
library;

class DisposableEmails {
  DisposableEmails._();

  /// The domain of [email], lowercased, or '' when there isn't one.
  static String domainOf(String email) {
    final at = email.lastIndexOf('@');
    if (at < 0 || at == email.length - 1) return '';
    var d = email.substring(at + 1).trim().toLowerCase();
    // A trailing dot is a legal, fully-qualified way to write a host, and
    // "mailinator.com." must not slip past a set lookup on "mailinator.com".
    while (d.endsWith('.')) {
      d = d.substring(0, d.length - 1);
    }
    return d;
  }

  /// Whether [email] is at a known throwaway domain.
  ///
  /// Subdomains count: several of these services hand out an unlimited supply
  /// of them (`anything.mailinator.com`), so the check walks the address's own
  /// suffixes rather than asking for an exact match.
  static bool isDisposable(String email) {
    final domain = domainOf(email);
    if (domain.isEmpty) return false;
    final parts = domain.split('.');
    for (var i = 0; i < parts.length - 1; i++) {
      if (domains.contains(parts.sublist(i).join('.'))) return true;
    }
    return false;
  }

  /// A user-facing reason, or null when the address is fine. Mirrors
  /// `VoipNumbers.reason` so the two gates read the same way at the call site.
  static String? reason(String email) => isDisposable(email)
      ? 'That is a temporary email service. Use an address you can still '
          'read next month — this is how you get back into your account.'
      : null;

  /// Known throwaway / temporary-inbox domains.
  ///
  /// Grown by adding, never by guessing: a false positive locks a real person
  /// out of their own recovery address, which is worse than letting one
  /// throwaway through. Anything uncertain belongs on the server list instead,
  /// where it can be taken back off without a build.
  static const Set<String> domains = {
    // Mailinator and friends — public inboxes, no password, endless subdomains
    'mailinator.com', 'mailinater.com', 'notmailinator.com', 'tmailinator.com',
    'reallymymail.com', 'sogetthis.com', 'suremail.info', 'thisisnotmyrealemail.com',
    // Guerrilla Mail
    'guerrillamail.com', 'guerrillamail.net', 'guerrillamail.org',
    'guerrillamail.biz', 'guerrillamail.de', 'guerrillamailblock.com',
    'sharklasers.com', 'grr.la', 'spam4.me', 'pokemail.net',
    // The "N-minute mail" family
    '10minutemail.com', '10minutemail.net', '10minemail.com', '20minutemail.com',
    'zehnminutenmail.de', 'tempmail.eu', 'tempmail2.com', 'tempmaildemo.com',
    'minuteinbox.com',
    // temp-mail / tmpmail
    'temp-mail.org', 'temp-mail.io', 'temp-mail.ru', 'tempmail.com',
    'tempmailo.com', 'tempail.com', 'tmpmail.org', 'tmpmail.net',
    'tempr.email', 'tempmailaddress.com', 'moakt.com', 'mailsac.com',
    'tempinbox.com', 'tempinbox.co.uk', 'temporaryinbox.com',
    'temporaryemail.net', 'temporaryforwarding.com', 'temporarymailaddress.com',
    'tempemail.com', 'tempemail.net', 'tempemail.biz', 'tempe-mail.com',
    'tempalias.com', 'tempomail.fr', 'temporarily.de',
    'tempmailer.com', 'tempmailer.de', 'mytemp.email',
    // YOPmail and its many aliases
    'yopmail.com', 'yopmail.net', 'yopmail.fr', 'yopweb.com', 'cool.fr.nf',
    'jetable.fr.nf', 'nospam.ze.tc', 'nomail.xl.cx', 'mega.zik.dj',
    'speed.1s.fr', 'courriel.fr.nf', 'moncourrier.fr.nf', 'monemail.fr.nf',
    'monmail.fr.nf',
    // TrashMail / Wegwerfmail (German throwaway services)
    'trashmail.com', 'trashmail.de', 'trashmail.net', 'trashmail.at',
    'trashmail.me', 'trashmail.ws', 'trash-mail.com', 'trash-mail.de',
    'trashemail.de', 'trashdevil.com', 'trashdevil.de', 'trashymail.com',
    'trashymail.net', 'trash2009.com', 'kurzepost.de', 'objectmail.com',
    'proxymail.eu', 'rcpt.at', 'wegwerfmail.de', 'wegwerfmail.net',
    'wegwerfmail.org', 'wegwerf-emails.de', 'wegwerfadresse.de',
    'wegwerfemail.com', 'wegwerfemail.de', 'weg-werf-email.de',
    'nurfuerspam.de', 'sinnlos-mail.de', 'smashmail.de', 'safetypost.de',
    'safersignup.de', 'sandelf.de', 'sofort-mail.de', 'spaminator.de',
    'twinmail.de', 'hulapla.de', 'plexolan.de', 'mailde.de', 'mailde.info',
    'topranklist.de', 'byom.de',
    // Other long-running throwaway inboxes
    'maildrop.cc', 'dispostable.com', 'fakeinbox.com', 'mailnesia.com',
    'mohmal.com', 'getnada.com', 'nada.email', 'inboxkitten.com',
    'emailondeck.com', 'mailcatch.com', 'mintemail.com', 'mailexpire.com',
    'throwawaymail.com', 'throwaway.email', 'throwawayemailaddress.com',
    'discard.email', 'discardmail.com', 'discardmail.de', 'deadaddress.com',
    'spamgourmet.com', 'spambog.com', 'spambog.de', 'spambog.ru',
    'mailmetrash.com', 'mytrashmail.com', 'anonbox.net', 'despam.it',
    'disposeamail.com', 'e4ward.com', 'emailtemporanea.com',
    'emailtemporanea.net', 'emltmp.com', 'filzmail.com', 'gishpuppy.com',
    'incognitomail.org', 'keepmymail.com', 'klzlk.com', 'lroid.com',
    'mail-temporaire.fr', 'mail333.com', 'mailbidon.com', 'mailbucket.org',
    'maileater.com', 'mailfreeonline.com', 'mailin8r.com', 'mailmoat.com',
    'mailnull.com', 'mailscrap.com', 'mailshell.com', 'mailsiphon.com',
    'mailzilla.com', 'mailzilla.org', 'mbx.cc', 'mierdamail.com',
    'mt2009.com', 'mt2014.com', 'mt2015.com', 'nepwk.com', 'nice-4u.com',
    'no-spam.ws', 'noclickemail.com', 'nomail2me.com', 'nospam4.us',
    'nospamfor.us', 'nowmymail.com', 'onewaymail.com', 'outlawspam.com',
    'owlpic.com', 'pancakemail.com', 'pjjkp.com', 'poofy.org', 'pookmail.com',
    'punkass.com', 'quickinbox.com', 'recode.me', 'regbypass.com', 'rmqkr.net',
    'rtrtr.com', 's0ny.net', 'safetymail.info', 'saynotospams.com',
    'selfdestructingmail.com', 'sendspamhere.com', 'shieldedmail.com',
    'shiftmail.com', 'sibmail.com', 'slaskpost.se', 'smellfear.com',
    'snakemail.com', 'sofimail.com', 'soodonims.com', 'spam.la', 'spam.su',
    'spamavert.com', 'spambob.com', 'spambob.net', 'spambob.org',
    'spambox.us', 'spamcannon.com', 'spamcannon.net', 'spamcorptastic.com',
    'spamcowboy.com', 'spamcowboy.net', 'spamcowboy.org', 'spamday.com',
    'spamfree24.com', 'spamfree24.de', 'spamfree24.eu', 'spamfree24.info',
    'spamfree24.net', 'spamfree24.org', 'spamherelots.com',
    'spamhereplease.com', 'spamhole.com', 'spamify.com', 'spamkill.info',
    'spaml.com', 'spaml.de', 'spammotel.com', 'spamobox.com', 'spamslicer.com',
    'spamspot.com', 'spamthis.co.uk', 'spamtroll.net', 'supergreatmail.com',
    'tilien.com', 'tittbit.in', 'toomail.biz', 'tradermail.info', 'trbvm.com',
    'turual.com', 'tyldd.com', 'uggsrock.com', 'upliftnow.com', 'uplipht.com',
    'venompen.com', 'veryrealemail.com', 'viditag.com', 'wh4f.org',
    'whyspam.me', 'willselfdestruct.com', 'winemaven.info', 'wronghead.com',
    'wuzup.net', 'wuzupmail.net', 'xagloo.com', 'xemaps.com', 'xents.com',
    'xmaily.com', 'xoxy.net', 'yep.it', 'yuurok.com', 'zippymail.info',
    'zoemail.net', 'zoemail.org', 'zomg.info', 'luxusmail.org', 'mailpoof.com',
    // Fake Name Generator's stable of throwaway domains
    'armyspy.com', 'cuvox.de', 'dayrep.com', 'einrot.com', 'fleckens.hu',
    'gustr.com', 'jourrapide.com', 'rhyta.com', 'superrito.com', 'teleworm.us',
  };
}
