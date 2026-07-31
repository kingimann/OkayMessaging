import 'package:flutter/material.dart';

import '../../state/legal_consent.dart';
import '../../theme/app_theme.dart';
import '../legal_screen.dart';

/// Blocks the app until the current Terms of Service and Privacy Policy are
/// agreed to — shown once on first sign-in, and again whenever the documents
/// are updated. Both documents are one tap away, so agreement is informed
/// rather than a checkbox reflex.
class LegalConsentScreen extends StatelessWidget {
  const LegalConsentScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final updated = LegalConsent.instance.hasAcceptedBefore;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 12, 28, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              CircleAvatar(
                radius: 34,
                backgroundColor:
                    AppColors.accentOn(context).withValues(alpha: 0.1),
                child: Icon(Icons.gavel_rounded,
                    size: 34, color: AppColors.accentOn(context)),
              ),
              const SizedBox(height: 20),
              Text(
                updated
                    ? 'We\'ve updated our terms'
                    : 'Terms & privacy',
                textAlign: TextAlign.center,
                style:
                    const TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 10),
              Text(
                updated
                    ? 'The Terms of Service and Privacy Policy have changed '
                        'since you last agreed. Please review and accept the '
                        'new versions to keep using OkayMessenger.'
                    : 'Before you start, take a look at how OkayMessenger '
                        'works: your messages are end-to-end encrypted, '
                        'relayed live between devices, and never stored on '
                        'our servers.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 14.5, height: 1.45, color: AppColors.subtle(context)),
              ),
              const SizedBox(height: 26),
              _DocTile(
                icon: Icons.description_outlined,
                title: 'Terms of Service',
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => LegalScreen.terms())),
              ),
              const SizedBox(height: 10),
              _DocTile(
                icon: Icons.lock_outline,
                title: 'Privacy Policy',
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => LegalScreen.privacy())),
              ),
              const Spacer(),
              Text(
                'By continuing you agree to the Terms of Service and '
                'Privacy Policy.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, color: AppColors.subtle(context)),
              ),
              const SizedBox(height: 12),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.accentOn(context),
                  foregroundColor: AppColors.onAccent(context),
                  minimumSize: const Size.fromHeight(52),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(26)),
                  textStyle: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600),
                ),
                onPressed: () => LegalConsent.instance.accept(),
                child: const Text('Agree and continue'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DocTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final VoidCallback onTap;

  const _DocTile({required this.icon, required this.title, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: isDark ? const Color(0xFF23262B) : const Color(0xFFF4F6F7),
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: Icon(icon),
        title: Text(title,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        trailing: const Icon(Icons.chevron_right, size: 20),
        onTap: onTap,
      ),
    );
  }
}
