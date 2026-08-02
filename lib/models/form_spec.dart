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

  /// A tick. Answered as 'Yes' or 'No' so a response reads without the form
  /// beside it.
  yesNo,
}

FormFieldKind _kindFrom(String? raw) => switch (raw) {
      'paragraph' => FormFieldKind.paragraph,
      'number' => FormFieldKind.number,
      'choice' => FormFieldKind.choice,
      'yesNo' => FormFieldKind.yesNo,
      _ => FormFieldKind.text,
    };

/// One question.
class FormFieldSpec {
  final String label;
  final FormFieldKind kind;
  final bool required;

  /// Only for [FormFieldKind.choice].
  final List<String> options;

  const FormFieldSpec({
    required this.label,
    this.kind = FormFieldKind.text,
    this.required = false,
    this.options = const [],
  });

  /// Whether this question is answerable as written. A choice with nothing to
  /// choose from is a dead end for whoever receives it, and the builder
  /// refuses to send one rather than letting somebody find out.
  bool get isUsable =>
      label.trim().isNotEmpty &&
      (kind != FormFieldKind.choice || options.length >= 2);

  Map<String, dynamic> toJson() => {
        'label': label,
        'kind': kind.name,
        'required': required,
        'options': options,
      };

  factory FormFieldSpec.fromJson(Map<String, dynamic> json) => FormFieldSpec(
        label: json['label'] as String? ?? '',
        kind: _kindFrom(json['kind'] as String?),
        required: json['required'] as bool? ?? false,
        options: [
          for (final o in (json['options'] as List?) ?? const []) '$o'
        ],
      );

  FormFieldSpec copyWith({
    String? label,
    FormFieldKind? kind,
    bool? required,
    List<String>? options,
  }) =>
      FormFieldSpec(
        label: label ?? this.label,
        kind: kind ?? this.kind,
        required: required ?? this.required,
        options: options ?? this.options,
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

  /// Whether [answers] satisfies [fields] — every required question answered.
  /// Pure, so the send button and the receiving end can agree without either
  /// trusting the other.
  static bool isComplete(
      List<FormFieldSpec> fields, List<String> answers) {
    for (var i = 0; i < fields.length; i++) {
      if (!fields[i].required) continue;
      if (i >= answers.length || answers[i].trim().isEmpty) return false;
    }
    return true;
  }
}
