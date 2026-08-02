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

  /// One stable id per question, so editor state (typed text, focus) moves
  /// WITH a question when it is reordered instead of staying in its slot.
  final List<int> _ids = [0];
  int _nextId = 1;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  bool get _sendable =>
      _title.text.trim().isNotEmpty &&
      _fields.isNotEmpty &&
      _fields.every((f) => f.isUsable);

  /// Common forms as starting points. Offered only while the form is still
  /// blank and gone the moment it is not — a suggestion, never content that
  /// arrives pre-filled unasked.
  static const _templates = <(String, List<FormFieldSpec>)>[
    ('RSVP', [
      FormFieldSpec(
          label: 'Coming?', kind: FormFieldKind.yesNo, required: true),
      FormFieldSpec(
          label: 'How many of you?',
          kind: FormFieldKind.number,
          showIfQ: 0,
          showIfIs: 'Yes'),
      FormFieldSpec(label: 'Why not?', showIfQ: 0, showIfIs: 'No'),
    ]),
    ('Order', [
      FormFieldSpec(label: 'Your name', required: true),
      FormFieldSpec(
          label: 'Size',
          kind: FormFieldKind.choice,
          required: true,
          options: ['S', 'M', 'L']),
      FormFieldSpec(label: 'Anything else?', kind: FormFieldKind.paragraph),
    ]),
    ('Feedback', [
      FormFieldSpec(
          label: 'How was it?', kind: FormFieldKind.rating, required: true),
      FormFieldSpec(
          label: 'What should change?', kind: FormFieldKind.paragraph),
    ]),
    ('Sign-up sheet', [
      FormFieldSpec(label: 'Your name', required: true),
      FormFieldSpec(label: 'Email', kind: FormFieldKind.email),
      FormFieldSpec(
          label: 'Which days?',
          kind: FormFieldKind.chooseMany,
          required: true,
          options: ['Mon', 'Tue', 'Wed', 'Thu', 'Fri']),
    ]),
  ];

  bool get _pristine =>
      _title.text.trim().isEmpty &&
      _fields.length == 1 &&
      _fields.first.label.trim().isEmpty;

  void _useTemplate(String title, List<FormFieldSpec> fields) =>
      setState(() {
        _title.text = title;
        _fields
          ..clear()
          ..addAll(fields);
        _ids.clear();
        for (final _ in fields) {
          _ids.add(_nextId++);
        }
      });

  void _send() {
    Navigator.of(context).pop((_title.text.trim(), List.of(_fields)));
  }

  /// Drops any "only ask if" that no longer holds together: pointing at
  /// itself or forwards, at a question that cannot gate, or at a value its
  /// question no longer offers. Run after every edit — a question's kind or
  /// options changing can orphan a condition two cards further down, where
  /// nobody is looking.
  void _repairConditions() {
    for (var i = 0; i < _fields.length; i++) {
      final q = _fields[i].showIfQ;
      if (q == null) continue;
      final broken = q < 0 ||
          q >= i ||
          !_fields[q].canGate ||
          !_fields[q].gateValues.contains(_fields[i].showIfIs);
      if (broken) _fields[i] = _fields[i].copyWith(clearShowIf: true);
    }
  }

  void _update(int i, FormFieldSpec f) => setState(() {
        _fields[i] = f;
        _repairConditions();
      });

  void _duplicate(int i) => setState(() {
        _fields.insert(i + 1, _fields[i]);
        _ids.insert(i + 1, _nextId++);
        // Everything past the insertion moved down one; conditions naming
        // those questions follow them. The copy's own condition needs no
        // help: it points backwards past the original, and those indices
        // did not move.
        for (var j = 0; j < _fields.length; j++) {
          final q = _fields[j].showIfQ;
          if (q != null && q > i) {
            _fields[j] = _fields[j].copyWith(showIfQ: q + 1);
          }
        }
        _repairConditions();
      });

  void _remove(int i) => setState(() {
        _fields.removeAt(i);
        _ids.removeAt(i);
        // Conditions are positional: everything after the gap moves up one,
        // and anything gated on the removed question loses its gate.
        for (var j = 0; j < _fields.length; j++) {
          final q = _fields[j].showIfQ;
          if (q == null) continue;
          if (q == i) {
            _fields[j] = _fields[j].copyWith(clearShowIf: true);
          } else if (q > i) {
            _fields[j] = _fields[j].copyWith(showIfQ: q - 1);
          }
        }
        _repairConditions();
      });

  void _move(int i, int delta) => setState(() {
        final j = i + delta;
        if (j < 0 || j >= _fields.length) return;
        final f = _fields.removeAt(i);
        final id = _ids.removeAt(i);
        _fields.insert(j, f);
        _ids.insert(j, id);
        // The swap renumbers both questions; conditions follow the question
        // they name, then the repair pass drops any that now point forwards.
        for (var k = 0; k < _fields.length; k++) {
          final q = _fields[k].showIfQ;
          if (q == i) {
            _fields[k] = _fields[k].copyWith(showIfQ: j);
          } else if (q == j) {
            _fields[k] = _fields[k].copyWith(showIfQ: i);
          }
        }
        _repairConditions();
      });

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
          if (_pristine) ...[
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final (name, fields) in _templates)
                  ActionChip(
                    label: Text(name),
                    onPressed: () => _useTemplate(name, fields),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          for (var i = 0; i < _fields.length; i++)
            _FieldEditor(
              key: ValueKey('field_${_ids[i]}'),
              index: i,
              fields: _fields,
              onChanged: (f) => _update(i, f),
              onRemove: _fields.length == 1 ? null : () => _remove(i),
              onMoveUp: i == 0 ? null : () => _move(i, -1),
              onMoveDown:
                  i == _fields.length - 1 ? null : () => _move(i, 1),
              onDuplicate: () => _duplicate(i),
            ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => setState(() {
              _fields.add(const FormFieldSpec(label: ''));
              _ids.add(_nextId++);
            }),
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
    required this.fields,
    required this.onChanged,
    required this.onRemove,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onDuplicate,
  });

  final int index;

  /// The whole form, not just this question: "only ask if" points at the
  /// questions above this one.
  final List<FormFieldSpec> fields;
  final ValueChanged<FormFieldSpec> onChanged;
  final VoidCallback? onRemove;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;
  final VoidCallback onDuplicate;

  FormFieldSpec get field => fields[index];

  static const _labels = {
    FormFieldKind.text: 'Short answer',
    FormFieldKind.paragraph: 'Long answer',
    FormFieldKind.number: 'Number',
    FormFieldKind.email: 'Email',
    FormFieldKind.phone: 'Phone',
    FormFieldKind.choice: 'Choose one',
    FormFieldKind.chooseMany: 'Choose many',
    FormFieldKind.dropdown: 'Dropdown',
    FormFieldKind.date: 'Date',
    FormFieldKind.rating: 'Rating',
    FormFieldKind.yesNo: 'Yes or no',
  };

  /// Questions above this one whose answer can gate it: a closed set of
  /// values to match, and enough of them to be a real fork.
  List<int> get _gates => [
        for (var q = 0; q < index; q++)
          if (fields[q].canGate && fields[q].gateValues.length >= 2) q
      ];

  String _gateName(int q) {
    final label = fields[q].label.trim();
    return label.isEmpty ? 'Question ${q + 1}' : label;
  }

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
            if (field.takesOptions) ...[
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
            const SizedBox(height: 10),
            TextFormField(
              initialValue: field.help,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Help text (optional)',
                helperText: 'Shown under the question — an example, a unit',
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => onChanged(field.copyWith(help: v)),
            ),
            if (_gates.isNotEmpty) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<int>(
                      initialValue: _gates.contains(field.showIfQ)
                          ? field.showIfQ
                          : null,
                      // Sized by the slot, not the widest label — a long
                      // question name must not overflow the half-width row.
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Only ask if…',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: [
                        const DropdownMenuItem(
                            value: null, child: Text('Always asked')),
                        for (final q in _gates)
                          DropdownMenuItem(
                              value: q,
                              child: Text(_gateName(q),
                                  overflow: TextOverflow.ellipsis)),
                      ],
                      onChanged: (q) => onChanged(q == null
                          ? field.copyWith(clearShowIf: true)
                          : field.copyWith(
                              showIfQ: q,
                              // A fresh gate starts on its first value: a
                              // condition with no value yet is not one.
                              showIfIs: fields[q].gateValues.first)),
                    ),
                  ),
                  if (_gates.contains(field.showIfQ)) ...[
                    const SizedBox(width: 8),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: fields[field.showIfQ!]
                                .gateValues
                                .contains(field.showIfIs)
                            ? field.showIfIs
                            : null,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'answered',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        items: [
                          for (final v in fields[field.showIfQ!].gateValues)
                            DropdownMenuItem(
                                value: v,
                                child: Text(v,
                                    overflow: TextOverflow.ellipsis)),
                        ],
                        onChanged: (v) =>
                            onChanged(field.copyWith(showIfIs: v ?? '')),
                      ),
                    ),
                  ],
                ],
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
                IconButton(
                  icon: const Icon(Icons.copy_outlined),
                  tooltip: 'Duplicate question',
                  onPressed: onDuplicate,
                ),
                IconButton(
                  icon: const Icon(Icons.arrow_upward),
                  tooltip: 'Move up',
                  onPressed: onMoveUp,
                ),
                IconButton(
                  icon: const Icon(Icons.arrow_downward),
                  tooltip: 'Move down',
                  onPressed: onMoveDown,
                ),
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
