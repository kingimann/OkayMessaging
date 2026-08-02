import 'package:flutter/material.dart';

import '../models/form_spec.dart';
import '../theme/app_theme.dart';

/// Builds a custom form to send into a conversation.
///
/// Returns the title and the questions; the caller turns them into a message.
/// It refuses to send a form that cannot be answered — an unlabelled question
/// or a choice with nothing to choose from is a dead end for whoever receives
/// it, and finding that out at their end is too late.
class FormBuilderScreen extends StatefulWidget {
  const FormBuilderScreen({super.key});

  @override
  State<FormBuilderScreen> createState() => _FormBuilderScreenState();
}

class _FormBuilderScreenState extends State<FormBuilderScreen> {
  final _title = TextEditingController();
  final List<FormFieldSpec> _fields = [
    const FormFieldSpec(label: '', kind: FormFieldKind.text),
  ];

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  bool get _sendable =>
      _title.text.trim().isNotEmpty &&
      _fields.isNotEmpty &&
      _fields.every((f) => f.isUsable);

  void _send() {
    Navigator.of(context).pop((_title.text.trim(), List.of(_fields)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('New form'),
        actions: [
          TextButton(
            onPressed: _sendable ? _send : null,
            child: const Text('Send'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
        children: [
          TextField(
            controller: _title,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'What is this form for?',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          Text(
            'Answers come back into this chat, encrypted like every other '
            'message. Nothing is stored on a server.',
            style: TextStyle(fontSize: 12.5, color: AppColors.subtle(context)),
          ),
          const SizedBox(height: 16),
          for (var i = 0; i < _fields.length; i++)
            _FieldEditor(
              key: ValueKey('field_$i'),
              index: i,
              field: _fields[i],
              onChanged: (f) => setState(() => _fields[i] = f),
              onRemove: _fields.length == 1
                  ? null
                  : () => setState(() => _fields.removeAt(i)),
            ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => setState(
                () => _fields.add(const FormFieldSpec(label: ''))),
            icon: const Icon(Icons.add),
            label: const Text('Add a question'),
          ),
        ],
      ),
    );
  }
}

class _FieldEditor extends StatelessWidget {
  const _FieldEditor({
    super.key,
    required this.index,
    required this.field,
    required this.onChanged,
    required this.onRemove,
  });

  final int index;
  final FormFieldSpec field;
  final ValueChanged<FormFieldSpec> onChanged;
  final VoidCallback? onRemove;

  static const _labels = {
    FormFieldKind.text: 'Short answer',
    FormFieldKind.paragraph: 'Long answer',
    FormFieldKind.number: 'Number',
    FormFieldKind.choice: 'Choose one',
    FormFieldKind.yesNo: 'Yes or no',
  };

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextFormField(
              initialValue: field.label,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: 'Question ${index + 1}',
                border: const OutlineInputBorder(),
              ),
              onChanged: (v) => onChanged(field.copyWith(label: v)),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              children: [
                for (final kind in FormFieldKind.values)
                  ChoiceChip(
                    label: Text(_labels[kind]!),
                    selected: field.kind == kind,
                    onSelected: (_) => onChanged(field.copyWith(kind: kind)),
                  ),
              ],
            ),
            if (field.kind == FormFieldKind.choice) ...[
              const SizedBox(height: 10),
              TextFormField(
                initialValue: field.options.join(', '),
                decoration: const InputDecoration(
                  labelText: 'Choices, separated by commas',
                  helperText: 'At least two, or there is nothing to choose',
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) => onChanged(field.copyWith(options: [
                  for (final o in v.split(','))
                    if (o.trim().isNotEmpty) o.trim()
                ])),
              ),
            ],
            Row(
              children: [
                Checkbox(
                  value: field.required,
                  onChanged: (v) =>
                      onChanged(field.copyWith(required: v ?? false)),
                ),
                const Text('Required'),
                const Spacer(),
                if (onRemove != null)
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Remove question',
                    onPressed: onRemove,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
