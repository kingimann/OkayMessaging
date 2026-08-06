import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

import '../legal/legal_content.dart';
import '../state/legal_store.dart';

/// Renders a set of [LegalSection]s (Privacy Policy or Terms) as a readable,
/// selectable document.
class LegalScreen extends StatelessWidget {
  final String title;
  final List<LegalSection> sections;

  const LegalScreen({super.key, required this.title, required this.sections});

  /// Convenience constructors for the two documents. They read the EFFECTIVE
  /// documents ([LegalStore] — the owner's published version when there is
  /// one, else the built-in defaults), so an update the owner published shows
  /// here without a new build.
  factory LegalScreen.privacy() => LegalScreen(
      title: 'Privacy Policy', sections: LegalStore.instance.privacy);
  factory LegalScreen.terms() => LegalScreen(
      title: 'Terms of Service', sections: LegalStore.instance.terms);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        children: [
          Text(LegalStore.instance.lastUpdated,
              style: TextStyle(color: AppColors.subtle(context), fontSize: 12.5)),
          const SizedBox(height: 16),
          for (final s in sections) ...[
            if (s.title.isNotEmpty) ...[
              Text(s.title,
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
            ],
            SelectableText(
              s.body,
              style: TextStyle(
                  fontSize: 14.5,
                  height: 1.5,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
          ],
        ],
      ),
    );
  }
}
