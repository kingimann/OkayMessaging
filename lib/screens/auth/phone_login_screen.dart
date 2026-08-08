import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../crypto/double_ratchet.dart';
import '../../crypto/identity_recovery.dart';
import '../../crypto/key_exchange.dart';
import '../../models/user.dart';
import '../../relay/relay_config.dart';
import '../../state/abuse_guard.dart';
import '../../state/platform_moderation.dart';
import '../../state/account_service.dart';
import '../../state/session.dart';
import '../../state/two_step.dart';
import '../../util/account_code.dart';
import '../../util/haptics.dart';
import '../../util/random_identity.dart';
import '../../util/voip_numbers.dart';
import '../../theme/app_theme.dart';
import '../../widgets/recovery_gate.dart';
import '../../widgets/user_avatar.dart';

/// Phone-number sign-in.
///
/// Two modes, chosen at build time by [AccountService.isEnabled]:
///
///  * **Local** (default) — the number is your identity, stored only on this
///    device; entering it signs you in instantly. No server involved.
///  * **Verified** (`--dart-define=REQUIRE_OTP=true`) — a real flow: enter
///    number → receive an SMS code → verify → choose a server-checked unique
///    username. Only the phone↔username mapping is ever stored on the server.
class PhoneLoginScreen extends StatefulWidget {
  const PhoneLoginScreen({super.key});

  @override
  State<PhoneLoginScreen> createState() => _PhoneLoginScreenState();
}

enum _Step { phone, identifier, code, emailCode, username, noNumber }

/// Which of the two things somebody is here to do.
///
/// They were one form. It always asked for a name — which is a sign-UP field —
/// so somebody coming back on a new phone was asked to invent one, and
/// somebody making an account was never told that is what was happening. The
/// steps after this were already split (a number the directory knows signs
/// straight in; a new one picks a username); only the front door was not.
enum _Mode { signIn, signUp }

/// Whether this build asks for a real, SMS-verified number.
///
/// Reads [AccountService.isEnabled], which comes from compile-time defines and
/// therefore cannot be varied inside a test — so the branch that decides which
/// sign-in form appears was untestable, and shipped with the numberless option
/// on the local form only. The iOS build sets REQUIRE_OTP, so on a phone that
/// button did not exist.
@visibleForTesting
bool? debugVerifiedModeOverride;

bool get _verifiedMode => debugVerifiedModeOverride ?? AccountService.isEnabled;

class _PhoneLoginScreenState extends State<PhoneLoginScreen>
    with SingleTickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _username = TextEditingController();
  final _phone = TextEditingController();
  final _code = TextEditingController();
  final _identifier = TextEditingController();
  final _password = TextEditingController();

  /// Whether the password is shown as typed. Off by default, and a way to
  /// look at it — a field somebody cannot read back is a field they mistype
  /// and blame the account for.
  bool _showPassword = false;

  /// A phone resolved from a username login — used in place of the typed
  /// number, and shown masked so signing in with a username doesn't print
  /// the full number back out.
  String? _identifierPhone;

  /// A display name from the directory, for sign-ins that never asked for
  /// one (username and email logins have no name field).
  String _resolvedName = '';

  /// The address an email login is mid-flight for.
  String _emailLogin = '';
  String _dialCode = '+1';
  bool _busy = false;
  _Step _step = _Step.phone;

  /// Signing in when this device remembers an account, creating one when it
  /// does not — which is what each of those people actually came to do.
  late _Mode _mode;

  bool get _signingUp => _mode == _Mode.signUp;

  String? _error;

  /// Shown while a remembered account exists — a one-tap way back in for
  /// someone who has signed in on this device before.
  bool _showWelcomeBack = false;

  @override
  void initState() {
    super.initState();
    _shake = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 420));
    final last = Session.instance.lastAccount;
    _mode = last == null ? _Mode.signUp : _Mode.signIn;
    if (last != null) {
      _showWelcomeBack = true;
      // Prefill everything, so even "use a different account" starts warm.
      _name.text = last.name == last.phone ? '' : last.name;
      _username.text = last.username;
      final m = RegExp(r'^(\+\d+)\s+(.*)$').firstMatch(last.phone);
      if (m != null) {
        _dialCode = m.group(1)!;
        _phone.text = m.group(2)!;
      } else {
        _phone.text = last.phone.replaceFirst(RegExp(r'^\+\d+\s*'), '');
      }
    }
  }

  /// One tap back into the remembered account: same identity, same two-step
  /// gate, none of the typing. (With SMS verification on, the code step still
  /// runs — the tap just submits the prefilled number.)
  Future<void> _continueAsLast() async {
    final last = Session.instance.lastAccount;
    if (last == null) return;
    if (AccountService.isEnabled) {
      _sendCode();
      return;
    }
    if (!await _passTwoStep()) return;
    setState(() => _busy = true);
    await Session.instance.signIn(
      phone: last.phone,
      name: last.name,
      username: last.username,
    );
  }

  /// The same one tap, for ANY profile remembered on this device — the
  /// verification appropriate to the account still runs: a texted code for
  /// a phone account, the recovery PIN for a numberless one. Only the
  /// typing is saved, never a check.
  Future<void> _continueAsKnown(AppUser account) async {
    if (AccountCode.isCode(account.phone)) {
      await _numberlessPinSignIn(
          account.phone, account.username, account.name);
      return;
    }
    if (AccountService.isEnabled) {
      _identifierPhone = account.phone;
      _resolvedName = account.name;
      await _run(() async {
        await AccountService.instance.sendCode(account.phone);
        if (mounted) {
          setState(() => _step = _Step.code);
          _startResendCountdown();
        }
      });
      return;
    }
    if (!await _passTwoStep()) return;
    setState(() => _busy = true);
    await Session.instance.signIn(
      phone: account.phone,
      name: account.name,
      username: account.username,
    );
  }

  /// Removes a remembered profile from THIS DEVICE's quick sign-in list, after
  /// confirming — because for a numberless account with no recovery backup,
  /// taking it off the list is the only way back in, so it must not vanish on a
  /// stray tap.
  Future<void> _confirmForget(AppUser a) async {
    final numberless = AccountCode.isCode(a.phone);
    final who = a.handle.isNotEmpty
        ? a.handle
        : (a.name.isEmpty ? a.phone : a.name);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove $who?'),
        content: Text(numberless
            ? 'This takes it off the sign-in list on this device. A numberless '
                'account signs back in ONLY with the recovery PIN it created — '
                'if you haven\'t saved that PIN, removing it here is the last '
                'way in. The account itself is not deleted.'
            : 'This takes it off the quick sign-in list on this device. You can '
                'sign back in any time with the number. The account itself is '
                'not deleted.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await Session.instance.forgetAccount(a.phone);
    if (mounted) setState(() {});
  }

  /// (flag, name, dial code) — shown in the Telegram-style country sheet.
  static const _countries = [
    ('🇺🇸', 'United States', '+1'),
    ('🇨🇦', 'Canada', '+1'),
    ('🇬🇧', 'United Kingdom', '+44'),
    ('🇮🇳', 'India', '+91'),
    ('🇦🇺', 'Australia', '+61'),
    ('🇯🇵', 'Japan', '+81'),
    ('🇩🇪', 'Germany', '+49'),
    ('🇫🇷', 'France', '+33'),
    ('🇧🇷', 'Brazil', '+55'),
    ('🇲🇽', 'Mexico', '+52'),
    ('🇳🇬', 'Nigeria', '+234'),
    ('🇿🇦', 'South Africa', '+27'),
    ('🇦🇪', 'UAE', '+971'),
    ('🇸🇦', 'Saudi Arabia', '+966'),
    ('🇹🇷', 'Türkiye', '+90'),
    ('🇮🇷', 'Iran', '+98'),
    ('🇵🇰', 'Pakistan', '+92'),
    ('🇵🇭', 'Philippines', '+63'),
    ('🇰🇷', 'South Korea', '+82'),
    ('🇨🇳', 'China', '+86'),
  ];
  String _flag = '🇨🇦';
  Timer? _resendTimer;
  int _resendIn = 0;

  /// Plays the code boxes' rejection shake — the answer arriving where the
  /// eyes already are, instead of only in an error box further down.
  /// Created in [initState], NOT lazily: a `late` initializer would run on
  /// first touch, and for a screen that never shook that first touch is
  /// `dispose()` — where creating a ticker is an error.
  late final AnimationController _shake;

  /// A code the server refused: shake, knock, and (when [clear] is set)
  /// empty the boxes so retyping starts clean rather than backspacing
  /// through six stale digits. Kept for a too-short code, minus the clear —
  /// wiping half-typed digits would punish the person mid-typing.
  void _codeRejected({bool clear = true}) {
    if (!mounted) return;
    Haptics.press();
    _shake.forward(from: 0);
    if (clear) _code.clear();
  }

  void _startResendCountdown() {
    _resendTimer?.cancel();
    setState(() => _resendIn = 30);
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() {
        _resendIn--;
        if (_resendIn <= 0) t.cancel();
      });
    });
  }

  /// Telegram-style searchable country sheet.
  Future<void> _pickCountry() async {
    final chosen = await showModalBottomSheet<(String, String, String)>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        builder: (context, controller) => ListView(
          controller: controller,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 10),
              child: Text('Choose a country',
                  style:
                      TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            ),
            for (final c in _countries)
              ListTile(
                leading: Text(c.$1, style: const TextStyle(fontSize: 24)),
                title: Text(c.$2),
                trailing: Text(c.$3,
                    style: TextStyle(
                        color: AppColors.subtle(context),
                        fontWeight: FontWeight.w600)),
                onTap: () => Navigator.pop(sheetContext, c),
              ),
          ],
        ),
      ),
    );
    if (chosen != null) {
      setState(() {
        _flag = chosen.$1;
        _dialCode = chosen.$3;
      });
    }
  }

  String get _fullPhone => '$_dialCode ${_phone.text.trim()}';

  /// The phone this sign-in is actually about: the resolved one when the
  /// user typed a username, the typed one otherwise.
  String get _loginPhone => _identifierPhone ?? _fullPhone;

  String get _signInName {
    final typed = _name.text.trim();
    return typed.isNotEmpty ? typed : _resolvedName;
  }

  @override
  void dispose() {
    _password.dispose();
    _resendTimer?.cancel();
    _shake.dispose();
    _identifier.dispose();
    _name.dispose();
    _username.dispose();
    _phone.dispose();
    _code.dispose();
    super.dispose();
  }

  // --- Local (instant) sign-in -------------------------------------------

  Future<void> _continueLocal() async {
    if (!_formKey.currentState!.validate()) return;
    // Spam-signup brake on the instant (no-OTP) path, when it's a new account.
    if (_signingUp && !AbuseGuard.instance.accountCreateAllowed()) {
      setState(() => _error = 'You\'ve created several accounts recently. '
          'Try again later.');
      return;
    }
    if (await _refuseIfBanned(_fullPhone)) return;
    if (!await _passTwoStep()) return;
    setState(() => _busy = true);
    // Blank fields get friendly random stand-ins rather than the raw
    // phone number and an untellable empty handle.
    await Session.instance.signIn(
      phone: _fullPhone,
      name: _name.text.trim().isEmpty
          ? RandomIdentity.displayName()
          : _name.text.trim(),
      username: _username.text.trim().isEmpty
          ? RandomIdentity.username()
          : _username.text.trim(),
      isSignup: _signingUp,
    );
    if (_signingUp) await AbuseGuard.instance.noteAccountCreated();
    // The auth gate reacts to the new session and shows the home screen.
  }

  /// When two-step verification is enabled on this device, require the PIN
  /// before completing sign-in. Returns true when allowed to proceed.
  Future<bool> _passTwoStep() async {
    final twoStep = TwoStepVerification.instance;
    if (!twoStep.enabled.value) return true;
    final locked = twoStep.lockedFor;
    if (locked > Duration.zero) {
      // Say the wait up front rather than taking a PIN just to refuse it.
      setState(() => _error = 'Too many wrong PINs. '
          'Try again in ${locked.inSeconds + 1}s.');
      return false;
    }
    final pin = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _TwoStepPrompt(),
    );
    if (pin == null) return false;
    if (!twoStep.verify(pin)) {
      if (mounted) {
        final nowLocked = twoStep.lockedFor;
        setState(() => _error = nowLocked > Duration.zero
            ? 'Too many wrong PINs. Try again in ${nowLocked.inSeconds + 1}s.'
            : 'Incorrect two-step verification PIN. '
                '${twoStep.attemptsLeft} tries left before a cooldown.');
      }
      return false;
    }
    return true;
  }

  // --- Verified (SMS OTP + server username) ------------------------------

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = _friendly(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _friendly(Object e) {
    final s = e.toString();
    // The VoIP/toll-free backstop throws its own already-friendly reason.
    if (s.contains('mobile number')) {
      return s.replaceFirst(RegExp(r'^[A-Za-z]*Error:\s*'), '');
    }
    if (s.contains('provider') || s.contains('not enabled') || s.contains('sms')) {
      return 'Couldn\'t send the code. The SMS provider may not be enabled yet.';
    }
    return 'Something went wrong. Please try again.';
  }

  /// A banned number is turned away at the door. Fails open (a network hiccup
  /// never blocks a legitimate new user); the server locks a banned account out
  /// anyway if this is somehow bypassed.
  Future<bool> _refuseIfBanned(String phone) async {
    if (!await PlatformModeration.instance.isPhoneBanned(phone)) return false;
    if (mounted) {
      setState(() => _error = 'This number is banned from OkayMessaging.');
    }
    return true;
  }

  Future<void> _sendCode() async {
    if (!_formKey.currentState!.validate()) return;
    if (await _refuseIfBanned(_loginPhone)) return;
    await _run(() async {
      await AccountService.instance.sendCode(_loginPhone);
      if (mounted) {
        setState(() => _step = _Step.code);
        _startResendCountdown();
      }
    });
  }

  void _submitCode() {
    if (_step == _Step.emailCode) {
      _verifyEmailCode();
    } else {
      _verifyCode();
    }
  }

  Future<void> _verifyCode() async {
    if (_code.text.trim().length < 4) {
      setState(() => _error = 'Enter the code we sent you.');
      _codeRejected(clear: false);
      return;
    }
    await _run(() async {
      await AccountService.instance.verifyCode(_loginPhone, _code.text);
      // A returning account already owns a username — signing in shouldn't
      // ask them to pick one again. Only a brand-new number sees that step.
      final existing =
          await AccountService.instance.usernameForPhone(_loginPhone);
      if (!mounted) return;
      if (existing != null && AccountService.isValidUsername(existing)) {
        _username.text = existing;
        if (!await _passTwoStep()) return;
        await Session.instance.signIn(
          phone: _loginPhone,
          name: _signInName,
          username: existing,
        );
        return;
      }
      // The number checks out but the directory has nobody under it, so
      // there is no account to sign in TO. That is not a failure — it is the
      // other thing this screen does — but it has to be said, and a new
      // account needs a name that signing in never asked for.
      setState(() {
        if (!_signingUp) {
          _mode = _Mode.signUp;
          _error = 'No account on that number yet — setting one up.';
        }
        _step = _Step.username;
      });
    });
    // Still on the code step with an error means the server said no.
    if (mounted && _error != null && _step == _Step.code) _codeRejected();
  }

  /// Sign-in step 1b: a username or email instead of a phone number. Either
  /// way the account's own second factor still runs — a code texted to the
  /// account's phone, or emailed to its address. Nothing new to guess.
  Future<void> _continueIdentifier() async {
    final raw = _identifier.text.trim();
    switch (AccountService.loginIdentifierKind(raw)) {
      case 'email':
        // A password if one was typed, a code if not. Both end in the same
        // place — a session on the account, whose phone IS the identity here.
        final password = _password.text;
        if (password.isNotEmpty) {
          await _run(() async {
            final phone =
                await AccountService.instance.signInWithPassword(raw, password);
            if (!mounted) return;
            if (phone == null) {
              setState(() => _error = _noPhoneOnAccount);
              return;
            }
            _password.clear();
            await _finishIdentifierSignIn(phone);
          });
          return;
        }
        await _run(() async {
          await AccountService.instance.sendEmailCode(raw);
          if (!mounted) return;
          setState(() {
            _emailLogin = raw;
            _step = _Step.emailCode;
          });
          _startResendCountdown();
        });
      case 'username':
        await _run(() async {
          final account =
              await AccountService.instance.accountForUsername(raw);
          if (!mounted) return;
          if (account == null) {
            setState(() => _error =
                'No account found for @${AccountService.normalizeUsername(raw)}.');
            return;
          }
          final (phone, name) = account;
          // A numberless account has no number to text a code to — its
          // recovery PIN is the way back in.
          if (AccountCode.isCode(phone)) {
            await _numberlessPinSignIn(phone, raw, name);
            return;
          }
          _identifierPhone = phone;
          _resolvedName = name;
          await AccountService.instance.sendCode(phone);
          if (!mounted) return;
          setState(() => _step = _Step.code);
          _startResendCountdown();
        });
      default:
        setState(() =>
            _error = 'Enter a username (like ada_l) or an email address.');
    }
  }

  /// Verifies an emailed code. The session it opens belongs to the account
  /// that attached the email — which carries the phone that IS the identity
  /// here. An email on no phone account is refused, not half signed in.
  Future<void> _verifyEmailCode() async {
    if (_code.text.trim().length < 4) {
      setState(() => _error = 'Enter the code we emailed you.');
      _codeRejected(clear: false);
      return;
    }
    await _run(() async {
      final phone = await AccountService.instance
          .verifyEmailCode(_emailLogin, _code.text);
      if (!mounted) return;
      if (phone == null) {
        setState(() => _error = _noPhoneOnAccount);
        return;
      }
      await _finishIdentifierSignIn(phone);
    });
    if (mounted && _error != null && _step == _Step.emailCode) {
      _codeRejected();
    }
  }

  /// The way back into an account that has no number to text: the recovery
  /// PIN. Opening the backup IS the authentication — it proves the person
  /// holds the one secret the account owner chose — and it hands back the
  /// same encryption identity in the same motion, so the account signs in
  /// able to read what was sealed to it. This used to be impossible: a
  /// signed-out numberless account had no way back in at all.
  Future<void> _numberlessPinSignIn(
      String code, String rawUsername, String name) async {
    final username = AccountService.normalizeUsername(rawUsername);
    final blob =
        await IdentityRecovery.fetch(code.replaceAll(RegExp(r'\D'), ''));
    if (!mounted) return;
    if (blob == null) {
      setState(() => _error =
          '@$username has no recovery backup, so it can\'t be signed back '
          'into. An account with no number signs back in with the recovery '
          'PIN it created.');
      return;
    }
    final hex = await showDialog<String>(
      context: context,
      builder: (_) => RestorePinDialog(blob: blob),
    );
    if (hex == null || !mounted) return;
    if (hex == 'lost') {
      // Nothing dishonest to offer: the backup opens with the PIN or not at
      // all, and an anonymous account cannot replace it.
      setState(() => _error =
          'Without the PIN, @$username can\'t be signed back into — the '
          'backup only opens with it.');
      return;
    }
    if (!await _passTwoStep()) return;
    await SecureKeyExchange.instance.adoptIdentity(hex);
    DoubleRatchet.instance.resetAllSessions();
    await IdentityRecovery.markReady();
    await Session.instance.signInWithoutNumber(
      name: name,
      username: username,
      code: code,
    );
    // The auth gate reacts to the new session and shows the home screen.
  }

  /// What both email routes end in: the account behind the address, signed
  /// into under the phone that IS its identity here.
  Future<void> _finishIdentifierSignIn(String phone) async {
    _identifierPhone = phone;
    final existing = await AccountService.instance.usernameForPhone(phone);
    if (!mounted) return;
    if (!await _passTwoStep()) return;
    await Session.instance.signIn(
      phone: phone,
      name: _signInName,
      username: existing ?? '',
    );
  }

  /// Said the same way wherever an email turns out to belong to no phone
  /// account, because it is the same fact and the same way out of it.
  static const String _noPhoneOnAccount =
      'That email isn\'t attached to a phone account, and the phone number '
      'is the account. Sign in with your number once, then add the email — '
      'and a password — in Settings.';

  /// Whether what has been typed looks like an address rather than a handle.
  bool get _emailTyped =>
      AccountService.loginIdentifierKind(_identifier.text) == 'email';

  /// Registering without a username no longer means a blank one: an account
  /// with no handle can be told to nobody, and a blank display name used to
  /// fall back to the raw phone number. Skipping mints a friendly random
  /// pair instead — both changeable in the profile at any time.
  Future<void> _skipUsername() async {
    if (!await _passTwoStep()) return;
    setState(() => _busy = true);
    final name = _signInName.trim().isEmpty
        ? RandomIdentity.displayName()
        : _signInName;
    var username = '';
    for (var i = 0; i < 3 && username.isEmpty; i++) {
      final candidate = RandomIdentity.username();
      if (!AccountService.isEnabled) {
        username = candidate;
        break;
      }
      try {
        if (await AccountService.instance
            .claimUsername(_loginPhone, candidate, name: name)) {
          username = candidate;
        }
        // Taken (vanishingly rare): loop mints another.
      } catch (_) {
        // Directory unreachable: keep the handle locally — the profile
        // screen claims it the next time the relay answers.
        username = candidate;
      }
    }
    if (username.isEmpty) username = RandomIdentity.username();
    await Session.instance.signIn(
      phone: _loginPhone,
      name: name,
      username: username,
    );
  }

  Future<void> _claimAndFinish() async {
    final u = AccountService.normalizeUsername(_username.text);
    if (!AccountService.isValidUsername(u)) {
      setState(() => _error = 'Choose a username (3+ letters, numbers, _ or .).');
      return;
    }
    if (!await _passTwoStep()) return;
    await _run(() async {
      final status =
          await AccountService.instance.checkUsername(_loginPhone, u);
      switch (status) {
        case UsernameStatus.taken:
          if (mounted) setState(() => _error = '@$u is already taken.');
          return;
        case UsernameStatus.invalid:
          if (mounted) setState(() => _error = 'That username isn\'t valid.');
          return;
        case UsernameStatus.available:
        case UsernameStatus.mine:
          // A blank display name gets a random one, not the phone number.
          final name = _signInName.trim().isEmpty
              ? RandomIdentity.displayName()
              : _signInName;
          // Claim is authoritative — the DB unique index rejects a name taken
          // between the check and now.
          final claimed = await AccountService.instance
              .claimUsername(_loginPhone, u, name: name);
          if (!claimed) {
            if (mounted) setState(() => _error = '@$u was just taken.');
            return;
          }
          await Session.instance.signIn(
            phone: _loginPhone,
            name: name,
            username: u,
          );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Telegram-style header: a big round accent badge with the
                  // app mark, a large bold title, and a roomy grey subtitle.
                  Center(
                    child: Container(
                      width: 112,
                      height: 112,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            const Color(0xFF35C48D),
                            AppColors.accentOn(context)
                          ],
                        ),
                      ),
                      child: const Icon(Icons.chat_bubble_rounded,
                          size: 52, color: Colors.white),
                    ),
                  ),
                  const SizedBox(height: 26),
                  Text(
                    'OkayMessenger',
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .headlineMedium
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 10),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      _subtitle(),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: AppColors.subtle(context),
                          fontSize: 15,
                          height: 1.35),
                    ),
                  ),
                  const SizedBox(height: 32),
                  // Steps slide/fade into each other instead of hard-cutting.
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    switchInCurve: Curves.easeOutCubic,
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween(
                                begin: const Offset(0, 0.04),
                                end: Offset.zero)
                            .animate(animation),
                        child: child,
                      ),
                    ),
                    child: Column(
                      key: ValueKey(
                          '${_step.name}_${_showWelcomeBack ? 'wb' : 'form'}'),
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: _body(),
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.red.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.error_outline,
                              size: 18, color: Colors.red),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(_error!,
                                style: const TextStyle(
                                    color: Colors.red, fontSize: 13)),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Text(
                    'Your number and messages stay on this device.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.subtle(context), fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _subtitle() {
    final welcome = _showWelcomeBack &&
        Session.instance.lastAccount != null &&
        _step == _Step.phone;
    if (welcome) return 'Welcome back — pick up where you left off';
    if (!_verifiedMode) {
      return _signingUp
          ? 'Your number and your name — that is the whole account'
          : 'Sign in with the number on your account';
    }
    switch (_step) {
      case _Step.phone:
        return _signingUp
            ? 'We will text a code to confirm the number is yours'
            : 'Sign in with the number on your account';
      case _Step.identifier:
        return 'Sign in with the username or email on your account';
      case _Step.code:
        // A username login resolves someone's number from the directory;
        // echoing it in full here would hand it to whoever typed the handle.
        return _identifierPhone != null
            ? 'Enter the code we texted to '
                '${AccountService.maskPhone(_identifierPhone!)}'
            : 'Enter the code we texted to $_fullPhone';
      case _Step.emailCode:
        return 'Enter the code we emailed to $_emailLogin';
      case _Step.username:
        return 'Pick a username others can find you by';
      case _Step.noNumber:
        return 'Just a name — a username is picked for you';
    }
  }

  List<Widget> _body() {
    final last = Session.instance.lastAccount;
    // The welcome-back card stands in for the phone step only. Once a code
    // has been sent, the step advances and the code screen takes over —
    // otherwise "Continue as" texts a code with nowhere to type it.
    if (_showWelcomeBack && last != null && _step == _Step.phone) {
      return _welcomeBack(last);
    }
    if (!_verifiedMode) {
      // The no-number step is a full screen of its own on this form too, so
      // "Sign up without a phone number" lands on the one-field step
      // field rather than erroring about one that isn't shown.
      if (_step == _Step.noNumber) return _noNumberFields();
      return [_modeSwitch(), ..._localFields()];
    }
    switch (_step) {
      case _Step.phone:
        return [
          _modeSwitch(),
          ..._phoneFields(
              onSubmit: _sendCode,
              cta: _signingUp ? 'Create account' : 'Send code'),
        ];
      case _Step.identifier:
        return _identifierFields();
      case _Step.code:
      case _Step.emailCode:
        return _codeFields();
      case _Step.username:
        return _usernameFields();
      case _Step.noNumber:
        return _noNumberFields();
    }
  }

  // --- Field groups ------------------------------------------------------

  /// Telegram-style input: softly filled, rounded, borderless until focus.
  InputDecoration _dec(String label,
      {IconData? icon, String? prefixText, String? helper}) {
    final scheme = Theme.of(context).colorScheme;
    OutlineInputBorder border(Color c, double w) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: c, width: w),
        );
    return InputDecoration(
      labelText: label,
      helperText: helper,
      prefixText: prefixText,
      prefixIcon: icon == null ? null : Icon(icon, size: 21),
      filled: true,
      fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
      border: border(Colors.transparent, 0),
      enabledBorder: border(Colors.transparent, 0),
      focusedBorder: border(AppColors.accentOn(context), 1.6),
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
    );
  }

  Widget _nameField() => TextFormField(
        controller: _name,
        textInputAction: TextInputAction.next,
        textCapitalization: TextCapitalization.words,
        autofillHints: const [AutofillHints.name],
        decoration: _dec('Your name', icon: Icons.person_outline),
        validator: (v) =>
            (v == null || v.trim().isEmpty) ? 'Enter a name' : null,
      );

  /// [required] on the numberless path, where the handle is the whole
  /// account; optional everywhere else — see [_continueWithoutNumber].
  Widget _usernameField({bool required = false}) => TextFormField(
        controller: _username,
        textInputAction: TextInputAction.next,
        autocorrect: false,
        enableSuggestions: false,
        decoration: _dec(required ? 'Username' : 'Username (optional)',
            icon: Icons.alternate_email,
            helper: 'Letters, numbers, _ and . — so people can find you'),
        validator: (v) {
          final u = AccountService.normalizeUsername(v ?? '');
          // Optional: empty is a choice, not a mistake. Only a non-empty
          // handle that breaks the format rules is worth stopping for.
          if (u.isEmpty && (v ?? '').trim().isEmpty) {
            return required ? 'Pick a username' : null;
          }
          if (!AccountService.isValidUsername(u)) {
            return 'At least 3 letters/numbers';
          }
          return null;
        },
      );

  Widget _phoneRow({VoidCallback? onSubmit}) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 112,
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: _pickCountry,
              child: InputDecorator(
                decoration: _dec('').copyWith(labelText: null),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(_flag, style: const TextStyle(fontSize: 18)),
                    const SizedBox(width: 6),
                    Text(_dialCode,
                        style:
                            const TextStyle(fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: TextFormField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              // iOS offers the device's own number above the keyboard —
              // the one number everybody types here and nobody remembers.
              autofillHints: const [AutofillHints.telephoneNumber],
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9 ]')),
              ],
              decoration: _dec('Phone number'),
              onFieldSubmitted: (_) => onSubmit?.call(),
              validator: (v) {
                final digits = (v ?? '').replaceAll(RegExp(r'\D'), '');
                if (digits.length < 6) return 'Enter a valid number';
                // Refuse toll-free / premium / VoIP ranges: an account needs a
                // number that can answer for it.
                return VoipNumbers.reason('$_dialCode $digits');
              },
            ),
          ),
        ],
      );

  Widget _cta(String label, VoidCallback onPressed) => FilledButton(
        onPressed: _busy ? null : onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.accentOn(context),
          foregroundColor: AppColors.onAccent(context),
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(26)),
          textStyle:
              const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700),
        ),
        child: _busy
            ? const SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white),
              )
            : Text(label),
      );

  /// The returning-user fast path: the remembered account as a card and one
  /// button, with the full form a tap away for anyone else.
  List<Widget> _welcomeBack(AppUser last) => [
        Material(
          color: Theme.of(context).brightness == Brightness.dark
              ? const Color(0xFF23262B)
              : const Color(0xFFF4F6F7),
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                UserAvatar(user: last, radius: 26),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        last.name.isEmpty ? last.phone : last.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 16.5, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        last.handle.isNotEmpty
                            ? '${last.handle} · ${last.phone}'
                            : last.phone,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 13, color: AppColors.subtle(context)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 18),
        _cta(
          'Continue as ${last.name.isEmpty ? last.phone : last.name.split(' ').first}',
          _continueAsLast,
        ),
        // Every other profile that has signed in on this device, one tap
        // each — the verification the account needs still runs; only the
        // typing is saved. Long-press removes a profile from the list.
        ...() {
          final lastDigits = last.phone.replaceAll(RegExp(r'\D'), '');
          final others = [
            for (final a in Session.instance.knownAccounts)
              if (a.phone.replaceAll(RegExp(r'\D'), '') != lastDigits) a
          ];
          if (others.isEmpty) return const <Widget>[];
          return <Widget>[
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerLeft,
              child: Text('Other accounts on this device',
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: AppColors.subtle(context))),
            ),
            for (final a in others)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: UserAvatar(user: a, radius: 20),
                title: Text(a.name.isEmpty ? a.phone : a.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: a.handle.isEmpty
                    ? null
                    : Text(a.handle,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                // A visible way to drop an account you don't want, not just a
                // hidden long-press: an X that removes it (after confirming),
                // beside the chevron that signs into it.
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.close, size: 20),
                      tooltip: 'Remove from this device',
                      color: AppColors.subtle(context),
                      visualDensity: VisualDensity.compact,
                      onPressed: _busy ? null : () => _confirmForget(a),
                    ),
                    const Icon(Icons.chevron_right, size: 20),
                  ],
                ),
                onTap: _busy ? null : () => _continueAsKnown(a),
                onLongPress: _busy ? null : () => _confirmForget(a),
              ),
          ];
        }(),
        const SizedBox(height: 6),
        TextButton(
          onPressed: _busy
              ? null
              : () => setState(() {
                    _showWelcomeBack = false;
                    // A different account starts BLANK. The last account's
                    // name, handle and number prefill only the one-tap way
                    // back IN — carrying them into this form dressed the
                    // next account in the previous person's identity.
                    _name.clear();
                    _username.clear();
                    _phone.clear();
                    _identifier.clear();
                    // And the RESOLVED phone goes too: a failed one-tap on
                    // a remembered profile left it set, and _loginPhone
                    // prefers it — the code for a freshly typed number
                    // would have gone to the tapped account instead.
                    _identifierPhone = null;
                    _resolvedName = '';
                  }),
          child: Text('Use a different account',
              style: TextStyle(color: AppColors.subtle(context))),
        ),
      ];

  /// Sign in | Create account. Two words that say which of the two things
  /// this screen is doing, and which fields it therefore needs.
  Widget _modeSwitch() => Padding(
        padding: const EdgeInsets.only(bottom: 22),
        child: SegmentedButton<_Mode>(
          segments: const [
            ButtonSegment(value: _Mode.signIn, label: Text('Sign in')),
            ButtonSegment(value: _Mode.signUp, label: Text('Create account')),
          ],
          selected: {_mode},
          showSelectedIcon: false,
          onSelectionChanged: _busy
              ? null
              : (picked) => setState(() {
                    _mode = picked.first;
                    _error = null;
                    // Creating an account is a NEW identity — drop any name or
                    // handle still prefilled from the remembered account so it
                    // doesn't wear the previous person's name.
                    if (_mode == _Mode.signUp) _dropStalePrefill();
                  }),
        ),
      );

  // Local instant flow: phone, plus who you are when it is a new account.
  List<Widget> _localFields() => [
        if (_signingUp) ...[
          _nameField(),
          const SizedBox(height: 14),
          _usernameField(),
          const SizedBox(height: 14),
        ],
        _phoneRow(onSubmit: _continueLocal),
        const SizedBox(height: 24),
        _cta(_signingUp ? 'Create account' : 'Sign in', _continueLocal),
        if (_signingUp) ...[
          const SizedBox(height: 6),
          TextButton(
            onPressed: _busy ? null : _startNoNumber,
            child: Text('Sign up without a phone number',
                style: TextStyle(color: AppColors.subtle(context))),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 2, 24, 0),
            child: Text(
              'No number, and no way for anyone to find you from their '
              'contacts. Chats work; the rest of the app needs a number.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 12, height: 1.35, color: AppColors.subtle(context)),
            ),
          ),
        ],
      ];

  /// Signs up with a username and nothing else — a code stands in for the
  /// number.
  ///
  /// The phone field is skipped rather than validated, so the form's own
  /// "enter a valid number" never fires on a path that deliberately has none.
  ///
  /// THE USERNAME IS REQUIRED HERE, and it is optional everywhere else. With a
  /// number, somebody who has you in their contacts finds you without knowing
  /// anything else about you. With no number there is nothing in anybody's
  /// phone to match, so a handle is the only thing left that another person
  /// can be told and can type — an account with neither is one nobody can
  /// start a conversation with.
  ///
  /// A display name is not: it defaults to the username, so the whole of
  /// signing up is one field.
  /// Drops the name/handle that were PREFILLED from the remembered account —
  /// but only while they still equal that account's, never text the person
  /// has typed for the account they're making now. Creating (or switching to)
  /// a new account must not inherit the previous person's identity.
  void _dropStalePrefill() {
    final last = Session.instance.lastAccount;
    if (last == null) return;
    if (_name.text.trim() == last.name.trim() &&
        last.name.trim() != last.phone.trim()) {
      _name.clear();
    }
    if (_username.text.trim() == last.username.trim()) _username.clear();
  }

  void _startNoNumber() => setState(() {
        _error = null;
        // A numberless sign-up is always a NEW account with a MINTED handle;
        // a prefilled name from the last account would carry over.
        _dropStalePrefill();
        _step = _Step.noNumber;
      });

  Future<void> _continueWithoutNumber() async {
    // Spam-signup brake: a name-only account is the cheapest to mint (no number,
    // no code), so cap how many one device can make in a day. On-device only —
    // a determined abuser on fresh devices needs a server-side signup limit.
    if (!AbuseGuard.instance.accountCreateAllowed()) {
      setState(() => _error = 'You\'ve created several accounts recently. '
          'Try again later.');
      return;
    }
    // A name-only account has no number to recover it with, and Supabase has
    // no session for it either — so signing out or deleting the app ends it for
    // good. Say that plainly and make them acknowledge it BEFORE the account is
    // made, not discover it the day they can't get back in.
    final goOn = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('This account can\'t be recovered'),
        content: const Text(
          'A name-only account lives only on this device. There\'s no phone '
          'number to sign back in with, so if you log out, switch phones, or '
          'delete the app, you CAN\'T get back into this account — your chats '
          'and everything in it are gone.\n\n'
          'Write down your account code and username from your profile, and '
          'add a phone number later if you want to be able to sign back in.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Go back'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('I understand, create it'),
          ),
        ],
      ),
    );
    if (goOn != true) return;
    if (!await _passTwoStep()) return;
    setState(() => _busy = true);
    // Mint the code first so the handle can be claimed in the directory
    // BEFORE the account exists locally — the handle is the only way anyone
    // can find this account, so an unclaimed handle is an unreachable
    // account.
    final code = AccountCode.mint();
    // Signing up this way is ONE field: a name (itself optional — a blank
    // one gets a random friendly stand-in). The handle is MINTED, not
    // chosen: a random pair of words nobody was asked to invent on the
    // spot, changeable in the profile later. Minting also makes "taken"
    // a retry instead of an error at the person signing up.
    final name = _name.text.trim().isEmpty
        ? RandomIdentity.displayName()
        : _name.text.trim();
    var username = '';
    for (var i = 0; i < 5 && username.isEmpty; i++) {
      final candidate = RandomIdentity.username();
      if (!RelayConfig.isEnabled) {
        username = candidate;
        break;
      }
      try {
        if (await AccountService.instance
            .claimUsername(code, candidate, name: name)) {
          username = candidate;
        }
        // Taken: loop mints another.
      } catch (_) {
        // Directory unreachable: keep the handle locally — the profile
        // screen claims it the next time the relay answers.
        username = candidate;
      }
    }
    if (username.isEmpty) username = RandomIdentity.username();
    await Session.instance.signInWithoutNumber(
      name: name,
      username: username,
      code: code,
      isSignup: true,
    );
    await AbuseGuard.instance.noteAccountCreated();
    // The auth gate reacts to the new session and shows the home screen.
  }

  // Verified step 1: a number, and who you are when it is a new account.
  //
  // SIGNING IN DOES NOT ASK FOR A NAME. The account already has one — the
  // directory hands it back with the username once the code checks out — so
  // asking is asking somebody to retype what the server is about to tell us.
  List<Widget> _phoneFields({required VoidCallback onSubmit, required String cta}) =>
      [
        if (_signingUp) ...[
          _nameField(),
          const SizedBox(height: 14),
        ],
        _phoneRow(onSubmit: onSubmit),
        const SizedBox(height: 24),
        _cta(cta, onSubmit),
        const SizedBox(height: 6),
        if (!_signingUp)
          TextButton(
            onPressed: _busy
                ? null
                : () => setState(() {
                      _error = null;
                      _step = _Step.identifier;
                    }),
            child: Text('Sign in with username or email',
                style: TextStyle(color: AppColors.subtle(context))),
          ),
        // A build that verifies numbers is still a build somebody may not
        // want to give one to, and there is nothing to verify about an
        // account that has none. It is a way to CREATE one, so it lives with
        // the other one of those.
        //
        // It moves to its own step rather than signing up on the spot: this
        // form has no username field — the handle is normally chosen after
        // the code checks out — so acting here could only ever show an error
        // about a field that is not on screen.
        if (_signingUp) ...[
          TextButton(
            onPressed: _busy ? null : _startNoNumber,
            child: Text('Sign up without a phone number',
                style: TextStyle(color: AppColors.subtle(context))),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 2, 24, 0),
            child: Text(
              'No number, and no way for anyone to find you from their '
              'contacts. Chats work; the rest of the app needs a number.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 12, height: 1.35, color: AppColors.subtle(context)),
            ),
          ),
        ],
      ];

  // Verified step 1b: one field that takes @username or email.
  List<Widget> _identifierFields() => [
        TextFormField(
          controller: _identifier,
          autofocus: true,
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
          decoration: _dec('Username or email',
              icon: Icons.person_search_outlined,
              helper: 'A password, or a code to your phone or inbox'),
          onFieldSubmitted: (_) => _continueIdentifier(),
          // The password field appears as soon as what is typed looks like an
          // address, so somebody who has one is not made to ask for a code
          // first and find the password box on the other side of it.
          onChanged: (_) => setState(() {}),
        ),
        if (_emailTyped) ...[
          const SizedBox(height: 14),
          TextFormField(
            controller: _password,
            obscureText: !_showPassword,
            autocorrect: false,
            enableSuggestions: false,
            autofillHints: const [AutofillHints.password],
            decoration: _dec('Password', icon: Icons.lock_outline).copyWith(
              suffixIcon: IconButton(
                icon: Icon(_showPassword
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined),
                tooltip: _showPassword ? 'Hide password' : 'Show password',
                onPressed: () => setState(() => _showPassword = !_showPassword),
              ),
              helperText: 'Leave it empty to get a code by email instead',
            ),
            onFieldSubmitted: (_) => _continueIdentifier(),
          ),
        ],
        const SizedBox(height: 24),
        _cta('Continue', _continueIdentifier),
        const SizedBox(height: 6),
        TextButton(
          onPressed: _busy
              ? null
              : () => setState(() {
                    _error = null;
                    _identifierPhone = null;
                    _step = _Step.phone;
                  }),
          child: Text('Use phone number instead',
              style: TextStyle(color: AppColors.subtle(context))),
        ),
      ];

  // Verified step 2: SMS code → Verify.
  List<Widget> _codeFields() => [
        // Six digit boxes over an invisible real field: the field carries the
        // input (keyboard, paste, autofill, tests), the boxes carry the look.
        // The whole row shakes sideways when the server refuses a code — a
        // damped sine, so it settles rather than stopping mid-swing.
        AnimatedBuilder(
          animation: _shake,
          builder: (context, child) => Transform.translate(
            offset: Offset(
                9 *
                    math.sin(_shake.value * math.pi * 4) *
                    (1 - _shake.value),
                0),
            child: child,
          ),
          child: Stack(
          alignment: Alignment.center,
          children: [
            Opacity(
              opacity: 0,
              child: TextFormField(
                controller: _code,
                autofocus: true,
                keyboardType: TextInputType.number,
                autofillHints: const [AutofillHints.oneTimeCode],
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(6),
                ],
                onFieldSubmitted: (_) => _submitCode(),
                // Telegram-style: verify the moment all six digits are in.
                onChanged: (v) {
                  setState(() {});
                  if (v.length == 6 && !_busy) _submitCode();
                },
              ),
            ),
            IgnorePointer(
              child: ValueListenableBuilder<TextEditingValue>(
                valueListenable: _code,
                builder: (context, value, _) {
                  final digits = value.text;
                  final isDark =
                      Theme.of(context).brightness == Brightness.dark;
                  return Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (var i = 0; i < 6; i++)
                        Container(
                          width: 44,
                          height: 52,
                          margin:
                              const EdgeInsets.symmetric(horizontal: 4),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: isDark
                                ? const Color(0xFF2A2E34)
                                : const Color(0xFFF0F2F3),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: i == digits.length
                                  ? AppColors.accentOn(context)
                                  : Colors.transparent,
                              width: 1.4,
                            ),
                          ),
                          child: Text(
                            i < digits.length ? digits[i] : '',
                            style: const TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w700),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
          ),
        ),
        const SizedBox(height: 24),
        _cta('Verify', _submitCode),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(() {
                        _code.clear();
                        _error = null;
                        // Back to wherever this code came from.
                        if (_step == _Step.emailCode ||
                            _identifierPhone != null) {
                          _identifierPhone = null;
                          _step = _Step.identifier;
                        } else {
                          _step = _Step.phone;
                        }
                        if (_showWelcomeBack) {
                          // Leaving the welcome-back fast path mid-code is
                          // the OTHER door to the form, and it kept the
                          // last account's name and handle warm — a new
                          // number typed here signed up wearing them.
                          _name.clear();
                          _username.clear();
                        }
                        _showWelcomeBack = false;
                      }),
              child: Text(_step == _Step.emailCode || _identifierPhone != null
                  ? 'Start over'
                  : 'Change number'),
            ),
            TextButton(
              onPressed: (_busy || _resendIn > 0)
                  ? null
                  : () {
                      _startResendCountdown();
                      if (_step == _Step.emailCode) {
                        _run(() =>
                            AccountService.instance.sendEmailCode(_emailLogin));
                      } else if (_identifierPhone != null) {
                        _run(() =>
                            AccountService.instance.sendCode(_identifierPhone!));
                      } else {
                        _sendCode();
                      }
                    },
              child: Text(
                  _resendIn > 0 ? 'Resend in ${_resendIn}s' : 'Resend code'),
            ),
          ],
        ),
      ];

  // Verified step 3: username → Continue, or skip it. A handle helps people
  // find you; requiring one helped nobody.
  List<Widget> _usernameFields() => [
        // Only when there isn't one. Signing in never asks for a name — so
        // arriving here from that path, on a number with no account, is the
        // one moment it has to be asked for.
        if (_signInName.trim().isEmpty) ...[
          _nameField(),
          const SizedBox(height: 14),
        ],
        _usernameField(),
        const SizedBox(height: 24),
        _cta('Continue', _claimAndFinish),
        const SizedBox(height: 6),
        TextButton(
          onPressed: _busy ? null : _skipUsername,
          child: Text('Skip for now',
              style: TextStyle(color: AppColors.subtle(context))),
        ),
      ];

  /// Numberless sign-up on the verified form: the username, and nothing else
  /// to fill in. A display name is optional and defaults to the handle — the
  /// account code is not a name anybody would recognise.
  List<Widget> _noNumberFields() => [
        // One field, and it is the NAME. The handle is minted for them —
        // asking a person to invent a unique username on the spot is the
        // highest-friction step of any sign-up, and the invented one is
        // changeable in the profile anyway.
        TextFormField(
          controller: _name,
          textCapitalization: TextCapitalization.words,
          decoration: _dec('Your name',
              icon: Icons.person_outline,
              helper: 'A username is picked for you — change it any time '
                  'in your profile'),
          onFieldSubmitted: (_) => _continueWithoutNumber(),
        ),
        const SizedBox(height: 16),
        // The one thing about this choice people most need to know up front:
        // there is no way back into a name-only account once it is left.
        Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            color: const Color(0xFFE67E22).withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: const Color(0xFFE67E22).withValues(alpha: 0.4)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.warning_amber_rounded,
                  size: 18, color: Color(0xFFE67E22)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'There\'s no way to sign back in. With no phone number, once '
                  'you log out or delete the app you can\'t get back into this '
                  'account — it lives only on this device.',
                  style: TextStyle(
                      fontSize: 12.5,
                      height: 1.4,
                      color: Theme.of(context).colorScheme.onSurface),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _cta('Create account', _continueWithoutNumber),
        const SizedBox(height: 6),
        TextButton(
          onPressed: _busy
              ? null
              : () => setState(() {
                    _error = null;
                    _step = _Step.phone;
                  }),
          child: Text('Use a phone number instead',
              style: TextStyle(color: AppColors.subtle(context))),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 2, 24, 0),
          child: Text(
            'No number, and no way for anyone to find you from their '
            'contacts. Chats work; the rest of the app needs a number.',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 12, height: 1.35, color: AppColors.subtle(context)),
          ),
        ),
      ];
}

/// Prompts for the two-step verification PIN during sign-in.
class _TwoStepPrompt extends StatefulWidget {
  const _TwoStepPrompt();

  @override
  State<_TwoStepPrompt> createState() => _TwoStepPromptState();
}

class _TwoStepPromptState extends State<_TwoStepPrompt> {
  final _pin = TextEditingController();

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final email = TwoStepVerification.instance.email;
    return AlertDialog(
      title: const Text('Two-step verification'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Enter your 6-digit PIN to sign in.'),
          const SizedBox(height: 12),
          TextField(
            controller: _pin,
            obscureText: true,
            autofocus: true,
            keyboardType: TextInputType.number,
            maxLength: 6,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 20, letterSpacing: 6),
            decoration: const InputDecoration(counterText: ''),
            onSubmitted: (v) => Navigator.of(context).pop(v),
          ),
          if (email.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('Forgot it? Recovery email: $email',
                  style: TextStyle(color: AppColors.subtle(context), fontSize: 12)),
            ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel')),
        TextButton(
            onPressed: () => Navigator.of(context).pop(_pin.text),
            child: const Text('Verify')),
      ],
    );
  }
}
