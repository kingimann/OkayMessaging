import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/user.dart';
import '../../state/account_service.dart';
import '../../state/session.dart';
import '../../state/two_step.dart';
import '../../theme/app_theme.dart';
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

class _PhoneLoginScreenState extends State<PhoneLoginScreen> {
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
    if (!await _passTwoStep()) return;
    setState(() => _busy = true);
    await Session.instance.signIn(
      phone: _fullPhone,
      name: _name.text.trim(),
      username: _username.text.trim(),
    );
    // The auth gate reacts to the new session and shows the home screen.
  }

  /// When two-step verification is enabled on this device, require the PIN
  /// before completing sign-in. Returns true when allowed to proceed.
  Future<bool> _passTwoStep() async {
    if (!TwoStepVerification.instance.enabled.value) return true;
    final pin = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _TwoStepPrompt(),
    );
    if (pin == null) return false;
    if (!TwoStepVerification.instance.verify(pin)) {
      if (mounted) {
        setState(() => _error = 'Incorrect two-step verification PIN.');
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
    if (s.contains('provider') || s.contains('not enabled') || s.contains('sms')) {
      return 'Couldn\'t send the code. The SMS provider may not be enabled yet.';
    }
    return 'Something went wrong. Please try again.';
  }

  Future<void> _sendCode() async {
    if (!_formKey.currentState!.validate()) return;
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

  /// Registering without a username is allowed — it only means nobody can
  /// find you by handle until you claim one in your profile. Sign-in itself
  /// never depended on it.
  Future<void> _skipUsername() async {
    if (!await _passTwoStep()) return;
    setState(() => _busy = true);
    await Session.instance.signIn(
      phone: _loginPhone,
      name: _signInName,
      username: '',
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
          // Claim is authoritative — the DB unique index rejects a name taken
          // between the check and now.
          final claimed = await AccountService.instance
              .claimUsername(_loginPhone, u, name: _name.text.trim());
          if (!claimed) {
            if (mounted) setState(() => _error = '@$u was just taken.');
            return;
          }
          await Session.instance.signIn(
            phone: _loginPhone,
            name: _signInName,
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
        return 'One field — the username people reach you by';
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
      // "Sign up with a username instead" lands somewhere with a username
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
        decoration: _dec('Your name', icon: Icons.person_outline),
        validator: (v) =>
            (v == null || v.trim().isEmpty) ? 'Enter a name' : null,
      );

  /// [required] on the numberless path, where the handle is the whole
  /// account; optional everywhere else — see [_continueWithoutNumber].
  Widget _usernameField({bool required = false}) => TextFormField(
        controller: _username,
        textInputAction: TextInputAction.next,
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
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9 ]')),
              ],
              decoration: _dec('Phone number'),
              onFieldSubmitted: (_) => onSubmit?.call(),
              validator: (v) {
                final digits = (v ?? '').replaceAll(RegExp(r'\D'), '');
                return digits.length < 6 ? 'Enter a valid number' : null;
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
        const SizedBox(height: 6),
        TextButton(
          onPressed:
              _busy ? null : () => setState(() => _showWelcomeBack = false),
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
            child: Text('Sign up with a username instead',
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
  void _startNoNumber() => setState(() {
        _error = null;
        _step = _Step.noNumber;
      });

  Future<void> _continueWithoutNumber() async {
    final username = AccountService.normalizeUsername(_username.text);
    if (!AccountService.isValidUsername(username)) {
      setState(() => _error = _username.text.trim().isEmpty
          ? 'Pick a username — with no number it is the only way anyone can '
              'reach you.'
          : 'That username needs at least 3 letters or numbers.');
      return;
    }
    if (!await _passTwoStep()) return;
    setState(() => _busy = true);
    await Session.instance.signInWithoutNumber(
      name: _name.text.trim(),
      username: username,
    );
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
            child: Text('Sign up with a username instead',
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
        Stack(
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
        _usernameField(required: true),
        const SizedBox(height: 14),
        TextFormField(
          controller: _name,
          textCapitalization: TextCapitalization.words,
          decoration: _dec('Display name (optional)',
              icon: Icons.person_outline, helper: 'Defaults to your username'),
          onFieldSubmitted: (_) => _continueWithoutNumber(),
        ),
        const SizedBox(height: 24),
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
