/// What a custom form asks, and what somebody answered.
///
/// A form is a richer poll, and it is built as one deliberately: it is sent
/// into a conversation as a message, the answers come back over the same
/// end-to-end encrypted path, and nothing about it is ever stored on a server
/// in a form anyone there could read. A form that posted to a table somewhere
/// would be the one feature in this app collecting people's answers in the
/// clear — and forms collect exactly the kind of answer worth protecting.
enum FormFieldKind {
  /// One line.
  text,

  /// Several — a comment, a reason, an address.
  paragraph,

  /// Digits only, still stored as text: a phone number with a leading zero
  /// stops being one the moment it is parsed as a number.
  number,

  /// Pick one of [FormFieldSpec.options].
  choice,

  /// Pick any number of [FormFieldSpec.options]. Answered as the picked
  /// options joined ', ' — options are entered comma-separated, so none can
  /// itself contain one, and the joined list reads without the form beside it.
  chooseMany,

  /// Pick one of [FormFieldSpec.options] from a list that folds away — the
  /// same question as [choice], for when the options would bury the form.
  dropdown,

  /// A calendar date, answered as YYYY-MM-DD so it reads (and sorts) as
  /// written anywhere.
  date,

  /// One to five stars, answered as 'N/5' so a bare number is never mistaken
  /// for an answer to something else.
  rating,

  /// A tick. Answered as 'Yes' or 'No' so a response reads without the form
  /// beside it.
  yesNo,
}

FormFieldKind _kindFrom(String? raw) => switch (raw) {
      'paragraph' => FormFieldKind.paragraph,
      'number' => FormFieldKind.number,
      'choice' => FormFieldKind.choice,
      'chooseMany' => FormFieldKind.chooseMany,
      'dropdown' => FormFieldKind.dropdown,
      'date' => FormFieldKind.date,
      'rating' => FormFieldKind.rating,
      'yesNo' => FormFieldKind.yesNo,
      _ => FormFieldKind.text,
    };

/// One question.
class FormFieldSpec {
  final String label;
  final FormFieldKind kind;
  final bool required;

  /// Shown under the label — what the question means, an example, a unit.
  final String help;

  /// Only for [FormFieldKind.choice], [FormFieldKind.chooseMany] and
  /// [FormFieldKind.dropdown].
  final List<String> options;

  /// Ask this question only when an EARLIER question's answer matches
  /// [showIfIs]. Null means always asked. The reference is positional —
  /// answers already are — and only backwards, so visibility can be decided
  /// in one forward pass and a form cannot ask about its own answer.
  final int? showIfQ;
  final String showIfIs;

  const FormFieldSpec({
    required this.label,
    this.kind = FormFieldKind.text,
    this.required = false,
    this.help = '',
    this.options = const [],
    this.showIfQ,
    this.showIfIs = '',
  });

  /// Whether this kind picks from [options].
  bool get takesOptions =>
      kind == FormFieldKind.choice ||
      kind == FormFieldKind.chooseMany ||
      kind == FormFieldKind.dropdown;

  /// Whether an answer to this question can gate a later one — it must offer
  /// a small closed set of values to match against, not free text.
  bool get canGate => takesOptions || kind == FormFieldKind.yesNo;

  /// The values a later question's condition may match against.
  List<String> get gateValues =>
      kind == FormFieldKind.yesNo ? const ['Yes', 'No'] : options;

  /// Whether this question is answerable as written. A choice with nothing to
  /// choose from is a dead end for whoever receives it, and the builder
  /// refuses to send one rather than letting somebody find out.
  bool get isUsable =>
      label.trim().isNotEmpty && (!takesOptions || options.length >= 2);

  Map<String, dynamic> toJson() => {
        'label': label,
        'kind': kind.name,
        'required': required,
        if (help.isNotEmpty) 'help': help,
        'options': options,
        if (showIfQ != null) 'showIfQ': showIfQ,
        if (showIfIs.isNotEmpty) 'showIfIs': showIfIs,
      };

  factory FormFieldSpec.fromJson(Map<String, dynamic> json) => FormFieldSpec(
        label: json['label'] as String? ?? '',
        kind: _kindFrom(json['kind'] as String?),
        required: json['required'] as bool? ?? false,
        help: json['help'] as String? ?? '',
        options: [
          for (final o in (json['options'] as List?) ?? const []) '$o'
        ],
        showIfQ: json['showIfQ'] as int?,
        showIfIs: json['showIfIs'] as String? ?? '',
      );

  FormFieldSpec copyWith({
    String? label,
    FormFieldKind? kind,
    bool? required,
    String? help,
    List<String>? options,
    int? showIfQ,
    String? showIfIs,
    bool clearShowIf = false,
  }) =>
      FormFieldSpec(
        label: label ?? this.label,
        kind: kind ?? this.kind,
        required: required ?? this.required,
        help: help ?? this.help,
        options: options ?? this.options,
        showIfQ: clearShowIf ? null : (showIfQ ?? this.showIfQ),
        showIfIs: clearShowIf ? '' : (showIfIs ?? this.showIfIs),
      );
}

/// One person's answers, in the order the questions were asked.
class FormResponse {
  /// Who answered, by display name. The digits are not carried: the chat
  /// already says who is in it, and a response is not a reason to write
  /// somebody's number into another message.
  final String from;

  /// Same length as the form's fields — a missing answer is an empty string
  /// rather than a shorter list, so answer N always belongs to question N
  /// even when the form was edited between sending and answering.
  final List<String> answers;

  final DateTime at;

  const FormResponse(
      {required this.from, required this.answers, required this.at});

  Map<String, dynamic> toJson() => {
        'from': from,
        'answers': answers,
        'at': at.toIso8601String(),
      };

  factory FormResponse.fromJson(Map<String, dynamic> json) => FormResponse(
        from: json['from'] as String? ?? '',
        answers: [
          for (final a in (json['answers'] as List?) ?? const []) '$a'
        ],
        at: DateTime.tryParse(json['at'] as String? ?? '') ?? DateTime(2000),
      );

  /// Whether question [i] is being asked, given what has been answered so
  /// far. Pure, and shared by the fill screen and [isComplete], so what the
  /// screen hides and what the send button waits for cannot disagree.
  ///
  /// A condition that cannot be evaluated — pointing at itself, forwards, or
  /// off the form — is ignored rather than obeyed: a mangled form should
  /// still be answerable, not silently unanswerable.
  static bool isShown(
      List<FormFieldSpec> fields, List<String> answers, int i) {
    if (i < 0 || i >= fields.length) return false;
    final q = fields[i].showIfQ;
    if (q == null) return true;
    if (q < 0 || q >= i) return true;
    if (!isShown(fields, answers, q)) return false;
    final answer = q < answers.length ? answers[q] : '';
    final wanted = fields[i].showIfIs;
    if (wanted.isEmpty) return true;
    // A choose-many answer is the picked options joined ', ' — matching any
    // one of them is what "if they picked X" means.
    if (fields[q].kind == FormFieldKind.chooseMany) {
      return answer.split(', ').contains(wanted);
    }
    return answer == wanted;
  }

  /// Whether [answers] satisfies [fields] — every required question that is
  /// actually being asked, answered. Pure, so the send button and the
  /// receiving end can agree without either trusting the other.
  static bool isComplete(
      List<FormFieldSpec> fields, List<String> answers) {
    for (var i = 0; i < fields.length; i++) {
      if (!fields[i].required) continue;
      if (!isShown(fields, answers, i)) continue;
      if (i >= answers.length || answers[i].trim().isEmpty) return false;
    }
    return true;
  }
}
