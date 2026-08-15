import 'package:flutter/material.dart';

import '../models/form_spec.dart';
import '../models/signature_ink.dart';
import '../theme/app_theme.dart';
import '../widgets/signature_pad.dart';
import '../widgets/spark_sheet.dart';

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
    this.payTo = '',
    this.payToName = '',
  });

  final String title;
  final List<FormFieldSpec> fields;

  /// A previous answer, when somebody is correcting one they already sent.
  final List<String> initial;

  /// Who a payment question pays, and what to call them. Empty when there is
  /// nobody to pay — your OWN copy of a form you sent, or a peer this device
  /// holds no number for — and a payment question then says so rather than
  /// drawing a button that leads nowhere.
  final String payTo;
  final String payToName;

  @override
  State<FormFillScreen> createState() => _FormFillScreenState();
}

class _FormFillScreenState extends State<FormFillScreen> {
  late final List<String> _answers = [
    for (var i = 0; i < widget.fields.length; i++)
      i < widget.initial.length ? widget.initial[i] : ''
  ];

  bool get _complete => FormResponse.isComplete(widget.fields, _answers);

  /// Whether what is holding up the send is a malformed answer rather than a
  /// missing one — the hint under the form should point at the right thing.
  bool get _shapeProblem {
    for (var i = 0; i < widget.fields.length; i++) {
      if (!FormResponse.isShown(widget.fields, _answers, i)) continue;
      if (FormResponse.formatProblem(widget.fields[i], _answers[i]) != null) {
        return true;
      }
    }
    return false;
  }

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
                  payTo: widget.payTo,
                  payToName: widget.payToName,
                  onChanged: (v) => _set(i, v),
                ),
              ),
          if (!_complete)
            Text(
              _shapeProblem
                  ? 'Fix the answers marked in red to send.'
                  : 'Answer the questions marked * to send.',
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
      required this.onChanged,
      this.payTo = '',
      this.payToName = ''});

  final FormFieldSpec field;
  final String value;
  final ValueChanged<String> onChanged;
  final String payTo;
  final String payToName;

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
          // Drawn, and said plainly under the box to be a mark rather than
          // proof of anything — see [SignatureInk].
          FormFieldKind.signature => SignaturePad(
              value: value,
              onChanged: onChanged,
            ),
          FormFieldKind.payment => _PayQuestion(
              field: field,
              paid: value.trim().isNotEmpty,
              payTo: payTo,
              payToName: payToName,
              onPaid: () => onChanged('Paid'),
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
              keyboardType: switch (field.kind) {
                FormFieldKind.number => TextInputType.number,
                FormFieldKind.email => TextInputType.emailAddress,
                FormFieldKind.phone => TextInputType.phone,
                _ => TextInputType.multiline,
              },
              // Digits stay text: a phone number with a leading zero stops
              // being one the moment it is parsed as a number.
              maxLines: field.kind == FormFieldKind.paragraph ? 4 : 1,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                // The author's example answer, greyed out until somebody
                // types. Empty when they set none, which is the common case.
                hintText:
                    field.placeholder.isEmpty ? null : field.placeholder,
                // Said while typing, where the typo is still on screen —
                // the same check the send button runs.
                errorText: FormResponse.formatProblem(field, value),
                // The range, where it can be read BEFORE the answer is wrong
                // rather than only as an error afterwards. Dropped while
                // there IS an error, so the box never shows both.
                helperText: FormResponse.formatProblem(field, value) == null
                    ? field.rangeLabel
                    : null,
              ),
              onChanged: onChanged,
            ),
        },
      ],
    );
  }
}

/// One answer as the author reads it back.
///
/// Most answers are their own text. A SIGNATURE is not: its answer is the
/// encoded strokes, and printing those would show somebody a wall of
/// coordinates instead of the mark they asked for — so it is drawn, at
/// thumbnail size, from the same normalised points the pad recorded.
class _AnswerText extends StatelessWidget {
  const _AnswerText({required this.field, required this.answer});

  final FormFieldSpec field;
  final String answer;

  @override
  Widget build(BuildContext context) {
    final given = answer.trim().isNotEmpty;
    if (field.kind == FormFieldKind.signature && given) {
      final ink = SignatureInk.decode(answer);
      if (!ink.isEmpty) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 64,
              width: 190,
              child: CustomPaint(
                painter: SignaturePainter(
                    ink: ink,
                    colour: AppColors.accentOn(context),
                    width: 1.8),
              ),
            ),
            Text(
              // The same sentence the pad shows the signer, shown again to
              // the person reading it back — this is where somebody is most
              // likely to mistake it for proof of something.
              'A drawn mark, not proof of who drew it.',
              style: TextStyle(fontSize: 11.5, color: AppColors.subtle(context)),
            ),
          ],
        );
      }
    }
    return Text(
      // A gap is said rather than left blank: an empty line reads as a
      // rendering fault.
      given ? answer : 'No answer',
      style: const TextStyle(fontSize: 15),
    );
  }
}

/// A payment question: the amount, and the one button that charges it.
///
/// The answer is recorded from the TRANSFER, not the tap —
/// [payFormRequest] returns true only when money actually moved, so a
/// declined card or a recipient who never finished onboarding leaves the
/// question unanswered rather than marked paid.
///
/// Once paid it becomes a plain line. There is no "unpay": the money is gone,
/// and a control offering to take the answer back would be describing
/// something the app cannot do.
class _PayQuestion extends StatelessWidget {
  const _PayQuestion({
    required this.field,
    required this.paid,
    required this.payTo,
    required this.payToName,
    required this.onPaid,
  });

  final FormFieldSpec field;
  final bool paid;
  final String payTo;
  final String payToName;
  final VoidCallback onPaid;

  @override
  Widget build(BuildContext context) {
    final money = '\$${(field.amountCents / 100).toStringAsFixed(2)}';
    if (paid) {
      return Row(
        children: [
          Icon(Icons.check_circle, size: 18, color: AppColors.accentOn(context)),
          const SizedBox(width: 8),
          Text('Paid $money',
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      );
    }
    if (payTo.trim().isEmpty) {
      // Your own copy of a form you sent, or a peer with no number here. A
      // disabled button would be a worse answer than a sentence.
      return Text(
        'Asks for $money. It can be paid from the chat this form was sent in.',
        style: TextStyle(fontSize: 13, color: AppColors.subtle(context)),
      );
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: FilledButton.icon(
        onPressed: () async {
          final ok = await payFormRequest(
            context,
            toPhone: payTo,
            toName: payToName,
            cents: field.amountCents,
            forLabel: field.label,
          );
          if (ok) onPaid();
        },
        icon: const Icon(Icons.payments_outlined),
        label: Text('Pay $money'),
      ),
    );
  }
}

/// The closed questions counted up, so twelve answers to "Which days?" do
/// not have to be read as twelve cards. Free-text questions are left to the
/// cards below — a tally of sentences is nothing.
class _Summary extends StatelessWidget {
  const _Summary({required this.fields, required this.responses});

  final List<FormFieldSpec> fields;
  final List<FormResponse> responses;

  @override
  Widget build(BuildContext context) {
    final lines = <Widget>[];
    for (var q = 0; q < fields.length; q++) {
      final String counted;
      if (fields[q].kind == FormFieldKind.rating) {
        final avg = FormResponse.ratingAverage(fields, responses, q);
        if (avg == null) continue;
        counted = '★ ${avg.toStringAsFixed(1)} average';
      } else if (fields[q].canGate) {
        final tally = FormResponse.tally(fields, responses, q);
        if (tally.isEmpty) continue;
        counted = [for (final e in tally.entries) '${e.key} ${e.value}']
            .join(' · ');
      } else {
        continue;
      }
      lines.add(Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(fields[q].label,
                style: TextStyle(
                    fontSize: 12.5, color: AppColors.subtle(context))),
            Text(counted,
                style: const TextStyle(
                    fontSize: 14.5, fontWeight: FontWeight.w600)),
          ],
        ),
      ));
    }
    if (lines.isEmpty) return const SizedBox.shrink();
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('At a glance',
                style:
                    TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            ...lines,
          ],
        ),
      ),
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
              itemCount: responses.length + 1,
              itemBuilder: (context, i) {
                if (i == 0) {
                  return _Summary(fields: fields, responses: responses);
                }
                final r = responses[i - 1];
                return Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // An unnamed response is an ANONYMOUS one — the
                        // responder's app left the name off because the form
                        // asked it to. Said in words rather than left blank,
                        // or the card reads as a bug.
                        Row(
                          children: [
                            if (r.from.trim().isEmpty) ...[
                              Icon(Icons.visibility_off_outlined,
                                  size: 15, color: AppColors.subtle(context)),
                              const SizedBox(width: 6),
                            ],
                            Text(
                              r.from.trim().isEmpty ? 'Anonymous' : r.from,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: r.from.trim().isEmpty
                                    ? AppColors.subtle(context)
                                    : null,
                              ),
                            ),
                          ],
                        ),
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
                            _AnswerText(
                              field: fields[q],
                              answer:
                                  q < r.answers.length ? r.answers[q] : '',
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
