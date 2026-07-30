import 'package:flutter/material.dart';

import '../legal/legal_content.dart';

/// Renders a set of [LegalSection]s (Privacy Policy or Terms) as a readable,
/// selectable document.
class LegalScreen extends StatelessWidget {
  final String title;
  final List<LegalSection> sections;

  const LegalScreen({super.key, required this.title, required this.sections});

  /// Convenience constructors for the two documents.
  factory LegalScreen.privacy() =>
      const LegalScreen(title: 'Privacy Policy', sections: privacyPolicy);
  factory LegalScreen.terms() =>
      const LegalScreen(title: 'Terms of Service', sections: termsOfService);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        children: [
          Text(legalLastUpdated,
              style: TextStyle(color: Colors.grey.shade500, fontSize: 12.5)),
          const SizedBox(height: 16),
          for (final s in sections) ...[
            Text(s.title,
                style: const TextStyle(
                    fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
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
