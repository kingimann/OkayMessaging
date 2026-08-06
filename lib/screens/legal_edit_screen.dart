import 'package:flutter/material.dart';

import '../legal/legal_content.dart';
import '../state/legal_store.dart';

/// Owner-only editor for the Terms of Service and Privacy Policy.
///
/// The owner edits each document as plain text; a line beginning with `# `
/// starts a new section heading. Publishing sends the documents to the
/// `legal-set` Edge Function (which enforces owner-only server-side) and bumps
/// the version, so every user is asked to agree to the new documents.
class LegalEditScreen extends StatefulWidget {
  const LegalEditScreen({super.key});

  @override
  State<LegalEditScreen> createState() => _LegalEditScreenState();
}

class _LegalEditScreenState extends State<LegalEditScreen> {
  late final TextEditingController _terms;
  late final TextEditingController _privacy;
  late final TextEditingController _updated;
  bool _publishing = false;

  @override
  void initState() {
    super.initState();
    _terms = TextEditingController(text: _flatten(LegalStore.instance.terms));
    _privacy =
        TextEditingController(text: _flatten(LegalStore.instance.privacy));
    _updated = TextEditingController(text: LegalStore.instance.lastUpdated);
  }

  @override
  void dispose() {
    _terms.dispose();
    _privacy.dispose();
    _updated.dispose();
    super.dispose();
  }

  /// Sections → editable text. A titled section becomes `# Title` then its body.
  static String _flatten(List<LegalSection> sections) => sections
      .map((s) => s.title.isEmpty ? s.body : '# ${s.title}\n\n${s.body}')
      .join('\n\n');

  /// Editable text → sections, splitting on `# ` heading lines. A document with
  /// no headings becomes a single untitled section.
  static List<LegalSection> _parse(String text) {
    final sections = <LegalSection>[];
    var title = '';
    final body = <String>[];
    void flush() {
      final b = body.join('\n').trim();
      if (title.isNotEmpty || b.isNotEmpty) sections.add(LegalSection(title, b));
      title = '';
      body.clear();
    }

    for (final line in text.split('\n')) {
      if (line.startsWith('# ')) {
        flush();
        title = line.substring(2).trim();
      } else {
        body.add(line);
      }
    }
    flush();
    if (sections.isEmpty) {
      final t = text.trim();
      if (t.isNotEmpty) sections.add(LegalSection('', t));
    }
    return sections;
  }

  Future<void> _publish() async {
    final terms = _parse(_terms.text);
    final privacy = _parse(_privacy.text);
    if (terms.isEmpty || privacy.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Both documents need some text before publishing.')));
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _publishing = true);
    final version = await LegalStore.instance.publish(
      terms: terms,
      privacy: privacy,
      lastUpdated: _updated.text.trim(),
    );
    if (!mounted) return;
    setState(() => _publishing = false);
    if (version != null) {
      messenger.showSnackBar(SnackBar(
          content: Text('Published — everyone will be asked to agree again '
              '(v$version).')));
      Navigator.of(context).pop();
    } else {
      messenger.showSnackBar(const SnackBar(
          content: Text('Couldn\'t publish. Owner-only, and the legal-set '
              'function must be deployed.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit legal documents'),
        actions: [
          if (_publishing)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                  child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))),
            )
          else
            TextButton(onPressed: _publish, child: const Text('Publish')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Text(
            'Update your Terms of Service and Privacy Policy. Start a heading '
            'with "# ". Publishing asks every user to agree again.',
            style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _updated,
            decoration: const InputDecoration(
              labelText: 'Last updated',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 20),
          _DocField(label: 'Terms of Service', controller: _terms),
          const SizedBox(height: 20),
          _DocField(label: 'Privacy Policy', controller: _privacy),
        ],
      ),
    );
  }
}

class _DocField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  const _DocField({required this.label, required this.controller});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          maxLines: null,
          minLines: 8,
          keyboardType: TextInputType.multiline,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: '# Section heading\n\nSection text…',
          ),
        ),
      ],
    );
  }
}
