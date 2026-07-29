import 'package:flutter/material.dart';

import '../state/account_email.dart';
import '../theme/app_theme.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/info_section.dart';
import '../widgets/pull_to_refresh.dart';

/// Add, change or remove the email on the account. The phone number is the
/// identity; the email is the second way back in if that number is lost.
class AccountEmailScreen extends StatefulWidget {
  const AccountEmailScreen({super.key});

  @override
  State<AccountEmailScreen> createState() => _AccountEmailScreenState();
}

class _AccountEmailScreenState extends State<AccountEmailScreen> {
  late final TextEditingController _controller =
      TextEditingController(text: AccountEmail.instance.email);
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // The link is clicked in a browser, so nothing tells the app it happened.
    // Opening this screen is the moment someone is asking, which makes it the
    // moment to go and find out.
    AccountEmail.instance.refreshVerification();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final entered = _controller.text.trim();
    if (!AccountEmail.isValid(entered)) {
      setState(() => _error = 'That doesn\'t look like an email address.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await AccountEmail.instance.setEmail(entered);
    if (!mounted) return;
    setState(() => _busy = false);
    final message = switch (result) {
      EmailSaveResult.verificationSent =>
        'Saved. Check $entered for a confirmation link.',
      EmailSaveResult.savedUnverified =>
        'Saved to this device. It can\'t be confirmed yet — see below.',
      EmailSaveResult.invalid => 'That doesn\'t look like an email address.',
    };
    if (result == EmailSaveResult.invalid) {
      setState(() => _error = message);
      return;
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _remove() async {
    final ok = await showAppConfirmDialog(
      context,
      icon: Icons.alternate_email,
      title: 'Remove email?',
      message: 'Without an email there\'s no way back into this account if '
          'you lose your phone number.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (!ok) return;
    await AccountEmail.instance.clear();
    if (!mounted) return;
    _controller.clear();
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Email removed')),
    );
  }

  Future<void> _resend() async {
    setState(() => _busy = true);
    final sent = await AccountEmail.instance.resendVerification();
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(sent
          ? 'Confirmation email sent.'
          : 'Couldn\'t send it — email sign-in isn\'t enabled on the server '
              'yet.'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Email address')),
      body: ListenableBuilder(
        listenable: AccountEmail.instance,
        builder: (context, _) {
          final store = AccountEmail.instance;
          return PullToRefresh(
            onRefresh: store.refreshVerification,
            child: ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                const SizedBox(height: 8),
                _WhyCard(hasEmail: store.isSet),
                const SizedBox(height: 8),
                if (store.isSet) _StatusTile(store: store, onResend: _resend),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                  child: TextField(
                    controller: _controller,
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    enabled: !_busy,
                    onChanged: (_) {
                      if (_error != null) setState(() => _error = null);
                    },
                    onSubmitted: (_) => _save(),
                    decoration: InputDecoration(
                      labelText: 'Email address',
                      hintText: 'you@example.com',
                      errorText: _error,
                      prefixIcon: const Icon(Icons.alternate_email),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14)),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.accentOn(context),
                      foregroundColor: AppColors.onAccent(context),
                      minimumSize: const Size.fromHeight(50),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(26)),
                    ),
                    onPressed: _busy ? null : _save,
                    child: Text(store.isSet ? 'Update email' : 'Add email'),
                  ),
                ),
                if (store.isSet)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
                    child: TextButton(
                      onPressed: _busy ? null : _remove,
                      child: const Text('Remove email',
                          style: TextStyle(color: Colors.red)),
                    ),
                  ),
                const SizedBox(height: 18),
                const _PrivacyNote(),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// What the email is actually for — so it reads as a security feature rather
/// than another field to fill in.
class _WhyCard extends StatelessWidget {
  final bool hasEmail;
  const _WhyCard({required this.hasEmail});

  @override
  Widget build(BuildContext context) {
    return InfoSection(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    hasEmail ? Icons.lock_outline : Icons.lock_open,
                    size: 18,
                    color: hasEmail ? null : const Color(0xFFF57F17),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    hasEmail
                        ? 'Your account has a second way in'
                        : 'Your account has one way in',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                hasEmail
                    ? 'Your phone number signs you in. This email is the '
                        'backup — it can recover the account if you lose that '
                        'number, and it doubles as the recovery address for '
                        'two-step verification.'
                    : 'Right now only your phone number can get you back into '
                        'this account. Add an email and you have a second way '
                        'in if you lose that number — and a recovery address '
                        'for two-step verification.',
                style: TextStyle(
                    fontSize: 13.5, color: Colors.grey.shade600, height: 1.35),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Whether the address has been confirmed, with a way to re-send.
class _StatusTile extends StatelessWidget {
  final AccountEmail store;
  final VoidCallback onResend;

  const _StatusTile({required this.store, required this.onResend});

  @override
  Widget build(BuildContext context) {
    final verified = store.isVerified;
    return InfoSection(
      children: [
        ListTile(
          leading: Icon(
            verified ? Icons.verified_outlined : Icons.schedule,
            color: verified ? Colors.green : const Color(0xFFF57F17),
          ),
          title: Text(store.email,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(verified
              ? 'Confirmed'
              : 'Not confirmed yet — saved on this device'),
          trailing: verified
              ? null
              : TextButton(onPressed: onResend, child: const Text('Resend')),
        ),
      ],
    );
  }
}

class _PrivacyNote extends StatelessWidget {
  const _PrivacyNote();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.shield_outlined, size: 16, color: Colors.grey.shade500),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Your email is never shown to your contacts and never added to '
              'the people directory. It stays on this device and in your '
              'encrypted backup.',
              style: TextStyle(fontSize: 12.5, color: Colors.grey.shade600),
            ),
          ),
        ],
      ),
    );
  }
}
