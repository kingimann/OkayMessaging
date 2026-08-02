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
            Padding(
              padding: const EdgeInsets.only(bottom: 18),
              child: _Question(
                field: widget.fields[i],
                value: _answers[i],
                onChanged: (v) => setState(() => _answers[i] = v),
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
      {required this.field, required this.value, required this.onChanged});

  final FormFieldSpec field;
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final label = field.required ? '${field.label} *' : field.label;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
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
                        for (var q = 0; q < fields.length; q++) ...[
                          Text(fields[q].label,
                              style: TextStyle(
                                  fontSize: 12.5,
                                  color: AppColors.subtle(context))),
                          Text(
                            // A gap is said rather than left blank: an empty
                            // line reads as a rendering fault.
                            q < r.answers.length && r.answers[q].trim().isNotEmpty
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
