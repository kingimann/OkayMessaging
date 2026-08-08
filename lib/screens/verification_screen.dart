import 'package:flutter/material.dart';

import '../state/account_email.dart';
import '../state/account_verification.dart';
import '../state/identity_verification.dart';
import '../state/session.dart';
import '../theme/app_theme.dart';
import '../widgets/info_section.dart';
import 'account_email_screen.dart';
import 'auth/numberless_verify_screen.dart';
import 'score_screen.dart';
import 'settings_widgets.dart';

/// Everything an account can prove about itself — phone, email, and government
/// ID — gathered on ONE screen. Each used to be a chip on the profile or a row
/// buried in a different settings screen; here they read as a single checklist
/// with one action apiece, and a header that says how far along you are.
///
/// Nothing new is stored: the three states come from [AccountVerification],
/// which reads the same stores the rest of the app does.
class VerificationScreen extends StatelessWidget {
  const VerificationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Verification')),
      body: ListenableBuilder(
        // Email and ID are ChangeNotifiers; phone is read imperatively (it
        // only changes on sign-in / the in-place number upgrade, both of
        // which rebuild this route anyway).
        listenable: Listenable.merge(
            [AccountEmail.instance, IdentityVerification.instance]),
        builder: (context, _) {
          final numberless = Session.instance.isNumberless;
          final phone = AccountVerification.phoneVerified;
          final email = AccountVerification.emailVerified;
          final id = AccountVerification.idVerified;
          final done = [phone, email, id].where((v) => v).length;

          return ListView(
            padding: const EdgeInsets.only(bottom: 40),
            children: [
              _Header(done: done, total: 3),
              settingsSectionLabel(context, 'Your verifications'),
              InfoSection(children: [
                _row(
                  context,
                  icon: Icons.sms_outlined,
                  title: 'Phone number',
                  verified: phone,
                  status: numberless
                      ? 'No number on this account'
                      : phone
                          ? 'Verified'
                          : 'Not verified',
                  actionLabel: phone ? null : 'Verify',
                  onAction: phone
                      ? null
                      : () => Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => const NumberlessVerifyScreen())),
                ),
                _row(
                  context,
                  icon: Icons.alternate_email,
                  title: 'Email address',
                  verified: email,
                  status: !AccountEmail.instance.isSet
                      ? 'Not added'
                      : email
                          ? 'Verified'
                          : 'Added — confirm it',
                  actionLabel: email ? null : 'Verify',
                  onAction: email
                      ? null
                      : () => Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => const AccountEmailScreen())),
                ),
                _row(
                  context,
                  icon: Icons.verified_outlined,
                  title: 'Government ID',
                  verified: id,
                  status: numberless
                      ? 'Needs a phone number first'
                      : id
                          ? 'Verified'
                          : IdentityVerification.instance.isPending
                              ? 'Pending'
                              : 'Not verified',
                  actionLabel: (id || numberless) ? null : 'Verify',
                  onAction: (id || numberless)
                      ? null
                      : () => Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => const ScoreScreen())),
                ),
              ]),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
                child: Text(
                  'Some features — like adding a community note — ask for all '
                  'three. The ID check is the same one that earns the blue '
                  'check.',
                  style: TextStyle(
                      fontSize: 12.5, color: AppColors.subtle(context)),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _row(
    BuildContext context, {
    required IconData icon,
    required String title,
    required bool verified,
    required String status,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    const green = Color(0xFF12B76A);
    return InfoTile(
      leading: Icon(verified ? Icons.check_circle : icon,
          color: verified ? green : null),
      title: title,
      subtitle: status,
      trailing: verified
          ? const Icon(Icons.check_circle, color: green, size: 20)
          : actionLabel == null
              ? null
              : FilledButton(
                  onPressed: onAction,
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    shape: const StadiumBorder(),
                  ),
                  child: Text(actionLabel),
                ),
      onTap: verified ? null : onAction,
    );
  }
}

class _Header extends StatelessWidget {
  final int done;
  final int total;
  const _Header({required this.done, required this.total});

  @override
  Widget build(BuildContext context) {
    final allDone = done == total;
    const green = Color(0xFF12B76A);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
      child: Row(
        children: [
          Icon(allDone ? Icons.verified : Icons.shield_outlined,
              size: 34, color: allDone ? green : AppColors.subtle(context)),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  allDone ? 'Fully verified' : '$done of $total verified',
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  allDone
                      ? 'Your phone, email and ID are all confirmed.'
                      : 'Confirm your phone, email and ID to unlock everything.',
                  style: TextStyle(
                      fontSize: 12.5, color: AppColors.subtle(context)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
