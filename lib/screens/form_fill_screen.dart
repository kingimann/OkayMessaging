import 'package:flutter/material.dart';

import '../models/form_spec.dart';
import '../theme/app_theme.dart';

/// Fills in a form somebody sent, and hands back the answers.
///
/// Answers are positional — one per question, in order, with an unanswered
/// optional question as an empty string rather than a gap. A shorter list
/// would silently shift every answer after it onto the wrong question.
class FormFillScreen extends StatefulWidget {
  const FormFillScreen({
    super.key,
    required this.title,
    required this.fields,
    this.initial = const [],
  });

  final String title;
  final List<FormFieldSpec> fields;

  /// A previous answer, when somebody is correcting one they already sent.
  final List<String> initial;

  @override
  State<FormFillScreen> createState() => _FormFillScreenState();
}

class _FormFillScreenState extends State<FormFillScreen> {
  late final List<String> _answers = [
    for (var i = 0; i < widget.fields.length; i++)
      i < widget.initial.length ? widget.initial[i] : ''
  ];

  bool get _complete => FormResponse.isComplete(widget.fields, _answers);

  void _set(int i, String v) => setState(() {
        _answers[i] = v;
        // Changing an answer can fold later questions away. Their answers go
        // with them: an answer to a question no longer being asked would
        // otherwise ride out with the response and read as an answer to it.
        for (var q = 0; q < widget.fields.length; q++) {
          if (!FormResponse.isShown(widget.fields, _answers, q)) {
            _answers[q] = '';
          }
        }
      });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title.isEmpty ? 'Form' : widget.title),
        actions: [
          TextButton(
            onPressed: _complete
                ? () => Navigator.of(context).pop(List.of(_answers))
                : null,
            child: const Text('Send'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
        children: [
          Text(
            'Your answers go back into this chat, encrypted. Only the person '
            'who sent the form can read them.',
            style: TextStyle(fontSize: 12.5, color: AppColors.subtle(context)),
          ),
          const SizedBox(height: 16),
          for (var i = 0; i < widget.fields.length; i++)
            if (FormResponse.isShown(widget.fields, _answers, i))
              Padding(
                padding: const EdgeInsets.only(bottom: 18),
                child: _Question(
                  // Keyed by position: hiding question 3 must not hand its
                  // text-field state to question 4 as the column reflows.
                  key: ValueKey('q_$i'),
                  field: widget.fields[i],
                  value: _answers[i],
                  onChanged: (v) => _set(i, v),
                ),
              ),
          if (!_complete)
            Text(
              'Answer the questions marked * to send.',
              style: TextStyle(
                  fontSize: 13, color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    );
  }
}

class _Question extends StatelessWidget {
  const _Question(
      {super.key,
      required this.field,
      required this.value,
      required this.onChanged});

  final FormFieldSpec field;
  final String value;
  final ValueChanged<String> onChanged;

  Future<void> _pickDate(BuildContext context) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.tryParse(value) ?? now,
      firstDate: DateTime(1900),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    final m = picked.month.toString().padLeft(2, '0');
    final d = picked.day.toString().padLeft(2, '0');
    onChanged('${picked.year}-$m-$d');
  }

  @override
  Widget build(BuildContext context) {
    final label = field.required ? '${field.label} *' : field.label;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        if (field.help.trim().isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(field.help,
              style:
                  TextStyle(fontSize: 12.5, color: AppColors.subtle(context))),
        ],
        const SizedBox(height: 8),
        switch (field.kind) {
          // Chips rather than radios: RadioListTile's group API is deprecated
          // in this Flutter, and one control for "pick one" reads better than
          // two that behave the same.
          FormFieldKind.choice => Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final option in field.options)
                  ChoiceChip(
                    label: Text(option),
                    selected: value == option,
                    // Tapping the chosen one clears it, so an optional
                    // question can be un-answered after a mis-tap.
                    onSelected: (_) =>
                        onChanged(value == option ? '' : option),
                  ),
              ],
            ),
          FormFieldKind.chooseMany => Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final option in field.options)
                  FilterChip(
                    label: Text(option),
                    selected: value.split(', ').contains(option),
                    onSelected: (picked) {
                      // Kept in the form's order, not the tapping order, so
                      // the same picks always read back as the same answer.
                      final chosen = value.split(', ').toSet();
                      picked ? chosen.add(option) : chosen.remove(option);
                      onChanged(field.options
                          .where(chosen.contains)
                          .join(', '));
                    },
                  ),
              ],
            ),
          FormFieldKind.dropdown => DropdownButtonFormField<String>(
              initialValue:
                  field.options.contains(value) ? value : null,
              // Sized by the screen, not the widest option, which nothing
              // stops from being a sentence.
              isExpanded: true,
              decoration:
                  const InputDecoration(border: OutlineInputBorder()),
              hint: const Text('Choose…'),
              items: [
                // The way back to no answer, so an optional dropdown is not
                // the one control a mis-tap commits forever.
                if (!field.required)
                  const DropdownMenuItem(
                      value: '', child: Text('No answer')),
                for (final option in field.options)
                  DropdownMenuItem(value: option, child: Text(option)),
              ],
              onChanged: (v) => onChanged(v ?? ''),
            ),
          FormFieldKind.date => OutlinedButton.icon(
              onPressed: () => _pickDate(context),
              icon: const Icon(Icons.event, size: 19),
              label: Text(value.isEmpty ? 'Pick a date' : value),
            ),
          FormFieldKind.rating => Row(
              children: [
                for (var star = 1; star <= 5; star++)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      star <= (int.tryParse(value.split('/').first) ?? 0)
                          ? Icons.star_rounded
                          : Icons.star_outline_rounded,
                      color: star <=
                              (int.tryParse(value.split('/').first) ?? 0)
                          ? Colors.amber.shade600
                          : AppColors.subtle(context),
                    ),
                    // Tapping the current rating clears it — same way out as
                    // a chip.
                    onPressed: () =>
                        onChanged(value == '$star/5' ? '' : '$star/5'),
                  ),
              ],
            ),
          // Answered in words rather than as a bare true/false, so a response
          // reads on its own without the form beside it.
          FormFieldKind.yesNo => Row(
              children: [
                for (final answer in ['Yes', 'No'])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(answer),
                      selected: value == answer,
                      onSelected: (_) =>
                          onChanged(value == answer ? '' : answer),
                    ),
                  ),
              ],
            ),
          _ => TextFormField(
              initialValue: value,
              keyboardType: field.kind == FormFieldKind.number
                  ? TextInputType.number
                  : TextInputType.multiline,
              // Digits stay text: a phone number with a leading zero stops
              // being one the moment it is parsed as a number.
              maxLines: field.kind == FormFieldKind.paragraph ? 4 : 1,
              decoration:
                  const InputDecoration(border: OutlineInputBorder()),
              onChanged: onChanged,
            ),
        },
      ],
    );
  }
}

/// What came back, one card per person.
class FormResponsesScreen extends StatelessWidget {
  const FormResponsesScreen(
      {super.key,
      required this.title,
      required this.fields,
      required this.responses});

  final String title;
  final List<FormFieldSpec> fields;
  final List<FormResponse> responses;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title.isEmpty ? 'Responses' : title),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(22),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              responses.length == 1 ? '1 response' : '${responses.length} responses',
              style:
                  TextStyle(fontSize: 12.5, color: AppColors.subtle(context)),
            ),
          ),
        ),
      ),
      body: responses.isEmpty
          ? Center(
              child: Text('Nobody has answered yet.',
                  style: TextStyle(color: AppColors.subtle(context))),
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              itemCount: responses.length,
              itemBuilder: (context, i) {
                final r = responses[i];
                return Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(r.from,
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 10),
                        for (var q = 0; q < fields.length; q++)
                          // A question their answers folded away was never
                          // asked of them — a "No answer" line would read as
                          // somebody declining a question they never saw.
                          if (FormResponse.isShown(fields, r.answers, q)) ...[
                            Text(fields[q].label,
                                style: TextStyle(
                                    fontSize: 12.5,
                                    color: AppColors.subtle(context))),
                            Text(
                              // A gap is said rather than left blank: an empty
                              // line reads as a rendering fault.
                              q < r.answers.length &&
                                      r.answers[q].trim().isNotEmpty
                                  ? r.answers[q]
                                  : 'No answer',
                              style: const TextStyle(fontSize: 15),
                            ),
                            const SizedBox(height: 10),
                          ],
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}
