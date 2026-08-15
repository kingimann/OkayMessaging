import 'package:flutter/material.dart';

import '../models/form_spec.dart';
import '../theme/app_theme.dart';

/// Builds a custom form — to send into a conversation, or to save for next
/// time.
///
/// Returns the title and the questions; the CALLER decides what that means.
/// A chat turns them into a message; the Forms screen writes them to
/// [SavedForms]. Keeping the builder ignorant of which is why one editor
/// serves both instead of a second, thinner one drifting away from this the
/// first time either changed — the same argument the thread screen made for
/// reusing `ChatScreen`.
///
/// It refuses to hand back a form that cannot be answered — an unlabelled
/// question or a choice with nothing to choose from is a dead end for whoever
/// receives it, and finding that out at their end is too late.
class FormBuilderScreen extends StatefulWidget {
  const FormBuilderScreen({
    super.key,
    this.initialTitle = '',
    this.initialFields = const [],
    this.initialAnonymous = false,
    this.title = 'New form',
    this.submitLabel = 'Send',
  });

  /// Opens on an existing form rather than a blank one. Empty is a new form.
  final String initialTitle;
  final List<FormFieldSpec> initialFields;

  /// The form's own settings, carried in and handed back out with the
  /// questions.
  final bool initialAnonymous;

  /// What the bar says, and what the button that hands the form back says —
  /// 'Send' from a chat, 'Save' from the Forms screen. The word is the whole
  /// difference the person needs to see; everything below it is identical.
  final String title;
  final String submitLabel;

  @override
  State<FormBuilderScreen> createState() => _FormBuilderScreenState();
}

class _FormBuilderScreenState extends State<FormBuilderScreen> {
  final _title = TextEditingController();
  final List<FormFieldSpec> _fields = [];

  /// One stable id per question, so editor state (typed text, focus) moves
  /// WITH a question when it is reordered instead of staying in its slot.
  final List<int> _ids = [];
  int _nextId = 0;

  /// Which questions are open.
  ///
  /// Keyed by the STABLE id, not the index — folding has to survive a reorder
  /// the same way the editor's own typed text does, and an index-keyed set
  /// would silently transfer "open" to whichever question moved into the slot.
  final Set<int> _open = {};

  /// The form's own settings, folded away by default: most forms never touch
  /// them, and a settings block above the first question would push the
  /// questions off the screen to serve the rare case.
  bool _settingsOpen = false;
  bool _anonymous = false;

  @override
  void initState() {
    super.initState();
    _title.text = widget.initialTitle;
    _anonymous = widget.initialAnonymous;
    _fields.addAll(widget.initialFields.isEmpty
        ? const [FormFieldSpec(label: '', kind: FormFieldKind.text)]
        : widget.initialFields);
    for (final _ in _fields) {
      _ids.add(_nextId++);
    }
    // A NEW form opens with its one blank question expanded — there is
    // nothing to survey and everything to fill in. An EXISTING one opens
    // fully folded: coming back to a finished form, the SHAPE is what you
    // want, and the question you actually came to change is one tap away
    // rather than buried under nine open cards.
    if (widget.initialFields.isEmpty) _open.add(_ids.first);
  }

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
    (
      'RSVP',
      [
        FormFieldSpec(
            label: 'Coming?', kind: FormFieldKind.yesNo, required: true),
        FormFieldSpec(
            label: 'How many of you?',
            kind: FormFieldKind.number,
            showIfQ: 0,
            showIfIs: 'Yes'),
        FormFieldSpec(label: 'Why not?', showIfQ: 0, showIfIs: 'No'),
      ]
    ),
    (
      'Order',
      [
        FormFieldSpec(label: 'Your name', required: true),
        FormFieldSpec(
            label: 'Size',
            kind: FormFieldKind.choice,
            required: true,
            options: ['S', 'M', 'L']),
        FormFieldSpec(label: 'Anything else?', kind: FormFieldKind.paragraph),
      ]
    ),
    (
      'Feedback',
      [
        FormFieldSpec(
            label: 'How was it?', kind: FormFieldKind.rating, required: true),
        FormFieldSpec(
            label: 'What should change?', kind: FormFieldKind.paragraph),
      ]
    ),
    (
      'Sign-up sheet',
      [
        FormFieldSpec(label: 'Your name', required: true),
        FormFieldSpec(label: 'Email', kind: FormFieldKind.email),
        FormFieldSpec(
            label: 'Which days?',
            kind: FormFieldKind.chooseMany,
            required: true,
            options: ['Mon', 'Tue', 'Wed', 'Thu', 'Fri']),
      ]
    ),
  ];

  bool get _pristine =>
      _title.text.trim().isEmpty &&
      _fields.length == 1 &&
      _fields.first.label.trim().isEmpty;

  void _useTemplate(String title, List<FormFieldSpec> fields) => setState(() {
        _title.text = title;
        _fields
          ..clear()
          ..addAll(fields);
        _ids.clear();
        for (final _ in fields) {
          _ids.add(_nextId++);
        }
        // Every id in the open set belonged to a question that no longer
        // exists, so it is rebuilt rather than left to go stale — and a
        // template is a starting point somebody is about to adapt, so the
        // first question opens while the rest stay surveyable.
        _open
          ..clear()
          ..add(_ids.first);
      });

  /// Hands the form back: title, questions, and the form's own settings.
  ///
  /// The settings ride as a NAMED record field rather than a third positional
  /// one, so a setting added later reads as `\$3.anonymous` at the call site
  /// instead of an unlabelled `\$4` nobody can interpret.
  void _send() {
    Navigator.of(context)
        .pop((_title.text.trim(), List.of(_fields), (anonymous: _anonymous)));
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

  /// The form's own settings — the ones that are about the FORM rather than
  /// any one question. Folded, because most forms want none of them.
  Widget _settingsSection(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md)),
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.tune, size: 20),
            title: const Text('Form settings',
                style: TextStyle(fontWeight: FontWeight.w600)),
            // What is ON, said on the folded row: a settings block that hides
            // whether anything inside it is set is a place people have to
            // open to find out, every time.
            subtitle: Text(_anonymous ? 'Anonymous answers' : 'Default'),
            trailing:
                Icon(_settingsOpen ? Icons.expand_less : Icons.expand_more),
            onTap: () => setState(() => _settingsOpen = !_settingsOpen),
          ),
          if (_settingsOpen) ...[
            const Divider(height: 1),
            SwitchListTile(
              value: _anonymous,
              onChanged: (v) => setState(() => _anonymous = v),
              title: const Text('Anonymous answers'),
              subtitle: const Text(
                // Every clause here is load-bearing and none of it may be
                // trimmed to a shorter promise than the transport keeps.
                'Answers arrive with no name attached. Their app is what '
                'leaves the name off, the same way it honours "forward and '
                'copy off" — and on an older build the delivery itself still '
                'identifies them. In a one-to-one chat it means nothing: '
                'there are only two of you.',
              ),
              isThreeLine: true,
            ),
            if (_anonymous)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline,
                        size: 16, color: AppColors.subtle(context)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        // The consequence, said where the switch is rather
                        // than discovered later by somebody wondering why a
                        // form has forty-one answers from forty people.
                        'Nobody can change an answer they already sent — '
                        'with no name on it there is nothing to correct.',
                        style: TextStyle(
                            fontSize: 12.5, color: AppColors.subtle(context)),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          TextButton(
            onPressed: _sendable ? _send : null,
            child: Text(widget.submitLabel),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
        children: [
          TextField(
            controller: _title,
            // Only on a blank form. Opening an existing one straight into
            // the keyboard hides the questions somebody came back to read.
            autofocus: widget.initialFields.isEmpty,
            textCapitalization: TextCapitalization.sentences,
            // The title IS the heading of this screen's content, so it is set
            // as one rather than boxed like the fields under it — a form's
            // name is not another question to answer.
            style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
            decoration: InputDecoration(
              hintText: 'What is this form for?',
              hintStyle: TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w700,
                  color: AppColors.subtle(context)),
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              filled: false,
              isDense: true,
              contentPadding: EdgeInsets.zero,
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 6),
          Text(
            // True either way, and it has to be: from a chat this is sent
            // now, from the Forms screen it is saved for later — but a form
            // never touches a server in either case, and a sentence that
            // named "this chat" would be wrong on one of the two screens.
            'Answers come back into the chat you send this from, encrypted '
            'like every other message. Nothing is stored on a server.',
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
          const SizedBox(height: 14),
          _settingsSection(context),
          const SizedBox(height: 14),
          // The questions, with a count and a way to fold the lot. Both only
          // once there is more than one — a "Collapse all" over a single
          // card, and a "1 question" tally, are chrome describing nothing.
          Row(
            children: [
              Text(
                '${_fields.length} '
                '${_fields.length == 1 ? 'question' : 'questions'}',
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.4,
                    color: AppColors.subtle(context)),
              ),
              const Spacer(),
              if (_fields.length > 1)
                TextButton(
                  onPressed: () => setState(() {
                    if (_open.isEmpty) {
                      _open.addAll(_ids);
                    } else {
                      _open.clear();
                    }
                  }),
                  child: Text(_open.isEmpty ? 'Expand all' : 'Collapse all'),
                ),
            ],
          ),
          const SizedBox(height: 4),
          for (var i = 0; i < _fields.length; i++)
            _FieldEditor(
              key: ValueKey('field_${_ids[i]}'),
              index: i,
              fields: _fields,
              expanded: _open.contains(_ids[i]),
              onToggle: () => setState(() {
                if (!_open.remove(_ids[i])) _open.add(_ids[i]);
              }),
              onChanged: (f) => _update(i, f),
              onRemove: _fields.length == 1 ? null : () => _remove(i),
              onMoveUp: i == 0 ? null : () => _move(i, -1),
              onMoveDown: i == _fields.length - 1 ? null : () => _move(i, 1),
              onDuplicate: () => _duplicate(i),
            ),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            onPressed: () => setState(() {
              _fields.add(const FormFieldSpec(label: ''));
              final id = _nextId++;
              _ids.add(id);
              // A question just added is a question about to be typed into,
              // so it arrives open. Nothing else is folded shut to make room:
              // closing somebody's other work to serve a tidy default is a
              // worse surprise than one extra open card.
              _open.add(id);
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
    required this.expanded,
    required this.onToggle,
    required this.onChanged,
    required this.onRemove,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onDuplicate,
  });

  final int index;

  /// Folded, a question is one row: its number, its label and what kind it
  /// is. Open, it is a screenful. Ten open cards was a wall nobody could see
  /// the shape of, which is what the fold is for.
  final bool expanded;
  final VoidCallback onToggle;

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
    FormFieldKind.signature: 'Signature',
    FormFieldKind.payment: 'Payment',
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

  /// The one-line summary a FOLDED question shows: what kind it is, plus any
  /// setting that changes what is being asked. Not everything — a folded row
  /// that lists every field is not folded.
  String get _summary {
    final parts = <String>[_labels[field.kind]!];
    if (field.required) parts.add('Required');
    if (field.takesOptions) {
      parts.add('${field.options.length} '
          '${field.options.length == 1 ? 'choice' : 'choices'}');
    }
    final range = field.rangeLabel;
    if (range != null) parts.add(range);
    if (field.kind == FormFieldKind.payment && field.amountCents > 0) {
      parts.add('\$${(field.amountCents / 100).toStringAsFixed(2)}');
    }
    if (field.showIfQ != null) parts.add('Conditional');
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final subtle = AppColors.subtle(context);
    final scheme = Theme.of(context).colorScheme;
    // A question that cannot be answered is the one thing the header has to
    // say while folded — otherwise the Send button is disabled and the reason
    // is inside a card that looks fine from the outside.
    final broken = !field.isUsable;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        side: BorderSide(
          color:
              broken ? scheme.error.withValues(alpha: 0.5) : Colors.transparent,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The header is the fold. It stays put when the card opens, so the
          // number, the summary and the chevron are in the same place either
          // way and tapping twice returns you exactly where you were.
          InkWell(
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
              child: Row(
                children: [
                  Container(
                    width: 26,
                    height: 26,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: subtle.withValues(alpha: 0.15),
                    ),
                    child: Text('${index + 1}',
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: subtle)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          field.label.trim().isEmpty
                              ? 'Untitled question'
                              : field.label.trim(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: field.label.trim().isEmpty ? subtle : null,
                            fontStyle: field.label.trim().isEmpty
                                ? FontStyle.italic
                                : null,
                          ),
                        ),
                        const SizedBox(height: 1),
                        Text(_summary,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: subtle)),
                      ],
                    ),
                  ),
                  if (broken)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: Tooltip(
                        message: field.label.trim().isEmpty
                            ? 'This question needs a label'
                            : field.kind == FormFieldKind.payment
                                ? 'This question needs an amount'
                                : 'This question needs at least two choices',
                        child: Icon(Icons.error_outline,
                            size: 18, color: scheme.error),
                      ),
                    ),
                  Icon(expanded ? Icons.expand_less : Icons.expand_more,
                      color: subtle),
                ],
              ),
            ),
          ),
          if (!expanded) const SizedBox(height: 2),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextFormField(
                    initialValue: field.label,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      // Numbered even though the header a few points above
                      // says the same: once a long card is scrolled into,
                      // that header is off screen and this is the only thing
                      // saying which question is being edited.
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
                          onSelected: (_) =>
                              onChanged(field.copyWith(kind: kind)),
                        ),
                    ],
                  ),
                  if (field.takesOptions) ...[
                    const SizedBox(height: 10),
                    TextFormField(
                      initialValue: field.options.join(', '),
                      decoration: const InputDecoration(
                        labelText: 'Choices, separated by commas',
                        helperText:
                            'At least two, or there is nothing to choose',
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
                      helperText:
                          'Shown under the question — an example, a unit',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (v) => onChanged(field.copyWith(help: v)),
                  ),
                  // Only on kinds that are typed into: a placeholder on a set of
                  // chips or a star rating has nowhere to go, and offering a field
                  // that does nothing is worse than not offering it.
                  if (field.takesPlaceholder) ...[
                    const SizedBox(height: 10),
                    TextFormField(
                      initialValue: field.placeholder,
                      decoration: const InputDecoration(
                        labelText: 'Example answer (optional)',
                        helperText: 'Greyed out inside the box until they type',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (v) =>
                          onChanged(field.copyWith(placeholder: v)),
                    ),
                  ],
                  if (field.kind == FormFieldKind.payment) ...[
              const SizedBox(height: 10),
              TextFormField(
                initialValue: field.amountCents == 0
                    ? ''
                    : (field.amountCents / 100).toStringAsFixed(2),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Amount',
                  prefixText: '\$',
                  helperText: 'What this question asks them to pay you',
                  border: OutlineInputBorder(),
                ),
                // Parsed to CENTS on the way in, so nothing downstream ever
                // holds a floating-point amount of money.
                onChanged: (v) => onChanged(field.copyWith(
                    amountCents:
                        ((double.tryParse(v.trim()) ?? 0) * 100).round())),
              ),
              const SizedBox(height: 8),
              Text(
                'They pay from their own wallet or card, to you. The money '
                'moves the same way it does anywhere else in the app — this '
                'question is only where it is asked for.',
                style:
                    TextStyle(fontSize: 12.5, color: AppColors.subtle(context)),
              ),
            ],
            if (field.kind == FormFieldKind.signature) ...[
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline,
                      size: 16, color: AppColors.subtle(context)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      // Said to the person ASKING for it as well as the one
                      // giving it. A form author who thinks this is binding
                      // is the one this sentence is for.
                      'They draw a mark with a finger. It is not proof of '
                      'who drew it, and it is not a legal signature.',
                      style: TextStyle(
                          fontSize: 12.5, color: AppColors.subtle(context)),
                    ),
                  ),
                ],
              ),
            ],
            if (field.takesRange) ...[
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            initialValue: field.min?.toString() ?? '',
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Least',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                            // An empty box means NO limit, which is why this can't
                            // ride copyWith's normal null-means-leave-alone: it
                            // clears both ends and puts back whichever still has a
                            // number in it.
                            onChanged: (v) => onChanged(field.copyWith(
                                clearRange: true,
                                min: int.tryParse(v.trim()),
                                max: field.max)),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextFormField(
                            initialValue: field.max?.toString() ?? '',
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Most',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                            onChanged: (v) => onChanged(field.copyWith(
                                clearRange: true,
                                min: field.min,
                                max: int.tryParse(v.trim()))),
                          ),
                        ),
                      ],
                    ),
                  ],
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
                                for (final v
                                    in fields[field.showIfQ!].gateValues)
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
        ],
      ),
    );
  }
}
