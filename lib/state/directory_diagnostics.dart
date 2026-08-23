import '../relay/relay_config.dart';
import 'account_service.dart';
import 'self_test.dart';
import 'session.dart';

/// What the live directory says about this account, gathered so [verdictFor]
/// can be reasoned about without a server.
class DirectoryFacts {
  /// The address this device believes it is — a real number, or an account
  /// code for an account with no number.
  final String myPhone;

  /// The handle this device believes it holds.
  final String myHandle;

  /// Whether there is a server session at all. Without one nothing publishes
  /// and nothing can be claimed.
  final bool signedIn;

  /// The handle the directory has at [myPhone], or null for no row at all.
  /// Distinguished from '' so "asked and there is nothing" is not confused
  /// with "could not ask".
  final String? handleAtMyAddress;

  /// The address the directory answers for [myHandle] — where a message
  /// addressed to this handle would actually go. Empty when nobody answers.
  final String addressForMyHandle;

  /// Whether the profile the directory publishes for [myHandle] carries any
  /// avatar at all. Null when there was nothing to read.
  final bool? publishedAvatar;

  const DirectoryFacts({
    required this.myPhone,
    required this.myHandle,
    required this.signedIn,
    required this.handleAtMyAddress,
    required this.addressForMyHandle,
    required this.publishedAvatar,
  });
}

/// "Check my profile" — the probe that answers why nobody can see or reach
/// this account.
///
/// **Why it exists.** Two reports kept coming back and neither could be told
/// apart from the outside: profile pictures not showing, and a message not
/// reaching the person it was addressed to. Both have the SAME commonest
/// cause and it is invisible from the app — the directory row.
///
/// A handle is the only thing another person can be told and can type, and
/// every server-side lookup joins on `usernames.phone`. Every one of those
/// lookups RETURNS rather than raises when it finds nothing, so an account
/// whose row is missing, or is stranded at a previous address, is not broken
/// loudly: it is INVISIBLE. Searches find the wrong row or none, a message
/// to the handle is addressed to whatever that row says, and a published
/// avatar lands on a row nobody reads.
///
/// The three questions it asks are the three that separate those cases, and
/// the second is the one worth having:
///
/// 1. Is there a row at MY address at all?
/// 2. **Does my own handle answer with MY address?** If it answers a
///    different one, a message sent to this handle goes to that address —
///    which is precisely "messaging doesn't go to the same person", and no
///    amount of looking at the messaging code would ever have shown it.
/// 3. Did the avatar actually publish?
///
/// Same shape as the other probes here: a pure [verdictFor] over facts, so
/// every branch is tested without a server.
class DirectorySelfTest {
  DirectorySelfTest._();

  static Future<SelfTestReport> run() async {
    final me = Session.instance.user.value;
    final phone = me?.phone ?? '';
    final handle = AccountService.normalizeUsername(me?.username ?? '');
    final signedIn = AccountService.isEnabled && RelayConfig.hasSession;

    String? at;
    var answers = '';
    bool? avatar;
    if (signedIn && phone.isNotEmpty) {
      at = await AccountService.instance.usernameForPhone(phone);
    }
    if (AccountService.isEnabled && AccountService.isValidUsername(handle)) {
      // Deliberately resolvePerson, not the raw table: it asks the way
      // everything else asks — the exact handle through find_people — so
      // what it answers is what a stranger opening a chat would get.
      final person = await AccountService.instance.resolvePerson(handle);
      answers = person?.phone ?? '';
      final profile = await AccountService.instance.publicProfile(handle);
      if (profile != null) {
        avatar = profile.avatarSeed.isNotEmpty ||
            profile.avatarFace.isNotEmpty ||
            profile.avatarGif.isNotEmpty ||
            profile.emoji.isNotEmpty;
      }
    }
    return reportFor(DirectoryFacts(
      myPhone: phone,
      myHandle: handle,
      signedIn: signedIn,
      handleAtMyAddress: at,
      addressForMyHandle: answers,
      publishedAvatar: avatar,
    ));
  }

  /// Digits only, so the several ways one number is written across this app
  /// ('+1 555 0100' and '+15550100') are not reported as two addresses.
  static String _d(String s) => s.replaceAll(RegExp(r'\D'), '');

  /// Whether the handle answers with this account's own address. False when
  /// it answers somebody else's; null when nobody answered at all, which is
  /// a different finding and must not read as a mismatch.
  static bool? handleIsMine(DirectoryFacts f) {
    if (f.addressForMyHandle.isEmpty) return null;
    return _d(f.addressForMyHandle) == _d(f.myPhone);
  }

  static SelfTestReport reportFor(DirectoryFacts f) => SelfTestReport(
        title: 'Check my profile',
        steps: stepsFor(f),
        verdict: verdictFor(f).$1,
        faulty: verdictFor(f).$2,
      );

  static List<DiagnosticStep> stepsFor(DirectoryFacts f) {
    final mine = handleIsMine(f);
    return [
      DiagnosticStep(
        'Signed in to the server',
        f.signedIn
            ? 'Yes — this account can publish and be found.'
            : 'No. Nothing can be published or claimed without a session.',
        f.signedIn ? CheckState.pass : CheckState.fail,
      ),
      DiagnosticStep(
        'This account is addressed as',
        f.myPhone.isEmpty ? 'nothing — no address at all.' : f.myPhone,
        f.myPhone.isEmpty ? CheckState.fail : CheckState.pass,
      ),
      DiagnosticStep(
        'Directory row at that address',
        switch (f.handleAtMyAddress) {
          null => 'None. Nobody can find this account by name.',
          '' => 'A row with no handle on it.',
          final h => '@$h',
        },
        f.handleAtMyAddress == null ? CheckState.fail : CheckState.pass,
      ),
      DiagnosticStep(
        '@${f.myHandle} reaches',
        switch (mine) {
          null => 'nobody — the directory has no answer for this handle.',
          true => 'this account. A message to it arrives here.',
          // The finding this whole probe exists for. Named, not hinted at.
          false => 'a DIFFERENT address (${f.addressForMyHandle}). A message '
              'sent to this handle goes there, not here.',
        },
        switch (mine) {
          null => CheckState.fail,
          true => CheckState.pass,
          false => CheckState.fail,
        },
      ),
      DiagnosticStep(
        'Avatar published',
        switch (f.publishedAvatar) {
          null => 'Nothing to read — there is no published profile.',
          true => 'Yes. Strangers see the picture, not initials.',
          false => 'No picture on the published profile.',
        },
        switch (f.publishedAvatar) {
          null => CheckState.unknown,
          true => CheckState.pass,
          false => CheckState.fail,
        },
      ),
    ];
  }

  /// The one sentence worth acting on. Ordered by which fault makes the ones
  /// under it meaningless: with no session nothing else can be true, and a
  /// handle pointing somewhere else explains a missing avatar rather than
  /// being a second problem.
  static (String, bool) verdictFor(DirectoryFacts f) {
    if (!f.signedIn) {
      return (
        'This account has no server session, so it cannot publish a profile '
        'or be found by name. An account with no phone number and no '
        'verified email has none by design — verifying either one fixes '
        'every line above.',
        true
      );
    }
    if (f.myHandle.isEmpty) {
      return (
        'This account has no handle, so there is nothing for anybody to look '
        'up. Pick one in Edit profile.',
        true
      );
    }
    final mine = handleIsMine(f);
    if (mine == false) {
      return (
        'THIS IS THE FAULT. @${f.myHandle} is registered to ${f.addressForMyHandle}, '
        'not to this account — almost always this account\'s OWN previous '
        'address, left behind when it gained a phone number or a verified '
        'email. Anyone messaging @${f.myHandle} reaches that address, and '
        'nothing published from here is ever read.\n\n'
        'Nothing in the app can move that row: an account code is public, so '
        'a server function that accepted one as proof would let anybody take '
        'anybody\'s handle. The way out is to pick a different handle in Edit '
        'profile, which claims cleanly at this address.',
        true
      );
    }
    if (f.handleAtMyAddress == null) {
      return (
        'This account has no directory row, so nobody can find it by name and '
        'nothing it publishes is readable. The app re-claims one at every '
        'launch; if this line keeps saying None, the handle is the thing to '
        'change in Edit profile.',
        true
      );
    }
    if (mine == null) {
      return (
        'The directory has a row for this account but does not answer for '
        '@${f.myHandle}. That is what "find me by username" being off does — '
        'check Privacy & security.',
        true
      );
    }
    if (f.publishedAvatar == false) {
      return (
        'Everything is addressed correctly, but no picture is published — so '
        'strangers see initials. Open Edit profile and save once; the profile '
        'publishes on save. If it stays empty, the server is refusing the '
        'write.',
        true
      );
    }
    return (
      'Nothing looks wrong from here: this account is findable at its own '
      'address, its handle reaches it, and its picture is published.',
      false
    );
  }
}
