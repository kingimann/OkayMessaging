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

  /// An address, checked for shape (something@something) before it goes out —
  /// a form is usually asking for it to reach somebody there, and a typo
  /// found at send time still belongs to the person who made it.
  email,

  /// A phone number, kept as typed. Same digits-stay-text rule as [number];
  /// the shape check only insists on enough digits to dial.
  phone,

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

  /// Sign here. Answered as the STROKES, normalised so the same signature
  /// draws at any size — see [SignatureInk].
  ///
  /// **It is a drawn mark, not a cryptographic signature**, and the app says
  /// so wherever one is asked for or shown. It proves somebody drew on a
  /// screen; it proves nothing about who they were. The app HAS real
  /// signatures — the sender keys every server broadcast is signed with —
  /// and calling this the same thing would be the most misleading sentence
  /// in the product.
  signature,

  /// Asks the responder to pay [FormFieldSpec.amountCents] to whoever sent
  /// the form. Answered 'Paid' once the transfer goes through, and blank
  /// until then — so marking the question required means the form cannot be
  /// sent back unpaid.
  ///
  /// The money moves down the SAME Stripe path as every other transfer in
  /// the app; nothing about payments is reimplemented here.
  payment,
}

FormFieldKind _kindFrom(String? raw) => switch (raw) {
      'paragraph' => FormFieldKind.paragraph,
      'number' => FormFieldKind.number,
      'email' => FormFieldKind.email,
      'phone' => FormFieldKind.phone,
      'choice' => FormFieldKind.choice,
      'chooseMany' => FormFieldKind.chooseMany,
      'dropdown' => FormFieldKind.dropdown,
      'date' => FormFieldKind.date,
      'rating' => FormFieldKind.rating,
      'yesNo' => FormFieldKind.yesNo,
      'signature' => FormFieldKind.signature,
      'payment' => FormFieldKind.payment,
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

  /// Greyed-out text inside the empty field — an EXAMPLE of the answer.
  /// Different from [help], which is a sentence about the question and stays
  /// on screen; a placeholder vanishes the moment somebody types, so it can
  /// only ever hint at the shape ("+1 416 555 0123"), never state a rule.
  final String placeholder;

  /// Range for [FormFieldKind.number], either end optional. Enforced in
  /// [FormResponse.formatProblem] — the ONE funnel the fill screen's live
  /// error and the send button's completeness check both already read, so a
  /// number outside the range is refused in both places without either
  /// growing its own copy of the rule.
  final int? min;
  final int? max;

  /// What [FormFieldKind.payment] asks for, in cents. Zero is "no amount
  /// set", which makes the question unanswerable — [isUsable] refuses it, the
  /// same way it refuses a choice with nothing to choose from.
  final int amountCents;

  const FormFieldSpec({
    required this.label,
    this.kind = FormFieldKind.text,
    this.required = false,
    this.help = '',
    this.options = const [],
    this.showIfQ,
    this.showIfIs = '',
    this.placeholder = '',
    this.min,
    this.max,
    this.amountCents = 0,
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
      label.trim().isNotEmpty &&
      (!takesOptions || options.length >= 2) &&
      // A payment question with no amount asks for nothing. Refused at build
      // time for the same reason a choice with one option is: finding out at
      // the far end is too late.
      (kind != FormFieldKind.payment || amountCents > 0);

  /// Written only when set, so a form built before these existed encodes
  /// byte-for-byte as it did — and an older build reading a newer form simply
  /// never sees the keys it has not heard of.
  Map<String, dynamic> toJson() => {
        'label': label,
        'kind': kind.name,
        'required': required,
        if (help.isNotEmpty) 'help': help,
        'options': options,
        if (showIfQ != null) 'showIfQ': showIfQ,
        if (showIfIs.isNotEmpty) 'showIfIs': showIfIs,
        if (placeholder.isNotEmpty) 'placeholder': placeholder,
        if (min != null) 'min': min,
        if (max != null) 'max': max,
        if (amountCents > 0) 'amountCents': amountCents,
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
        placeholder: json['placeholder'] as String? ?? '',
        min: (json['min'] as num?)?.toInt(),
        max: (json['max'] as num?)?.toInt(),
        amountCents: (json['amountCents'] as num?)?.toInt() ?? 0,
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
    String? placeholder,
    int? min,
    int? max,
    int? amountCents,
    // Null is a real value for a range end, so it cannot double as "leave
    // alone" the way it does for the strings. [clearRange] says "replace the
    // range with EXACTLY what is passed": on its own it clears both ends, and
    // with one end named it sets that one and clears the other. Without it a
    // range end can only ever be set, never removed.
    bool clearRange = false,
  }) =>
      FormFieldSpec(
        label: label ?? this.label,
        kind: kind ?? this.kind,
        required: required ?? this.required,
        help: help ?? this.help,
        options: options ?? this.options,
        showIfQ: clearShowIf ? null : (showIfQ ?? this.showIfQ),
        showIfIs: clearShowIf ? '' : (showIfIs ?? this.showIfIs),
        placeholder: placeholder ?? this.placeholder,
        min: clearRange ? min : (min ?? this.min),
        max: clearRange ? max : (max ?? this.max),
        amountCents: amountCents ?? this.amountCents,
      );

  /// Whether this kind takes a range. Only [FormFieldKind.number]: a range on
  /// a date would be a different control, and pretending a text field has one
  /// would be a rule nobody could see.
  bool get takesRange => kind == FormFieldKind.number;

  /// Whether this kind is typed into, and so can show a [placeholder].
  bool get takesPlaceholder =>
      kind == FormFieldKind.text ||
      kind == FormFieldKind.paragraph ||
      kind == FormFieldKind.number ||
      kind == FormFieldKind.email ||
      kind == FormFieldKind.phone;

  /// The range in words, for the builder's summary and the fill screen's
  /// hint. Null when there is no range to say.
  String? get rangeLabel {
    if (!takesRange) return null;
    if (min != null && max != null) return 'Between $min and $max';
    if (min != null) return '$min or more';
    if (max != null) return '$max or less';
    return null;
  }
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

  /// What is wrong with [answer]'s shape for this [field], said in a
  /// sentence — or null when nothing is. An empty answer is never a shape
  /// problem; whether emptiness is allowed is [FormFieldSpec.required]'s
  /// question, not this one's.
  static String? formatProblem(FormFieldSpec field, String answer) {
    final a = answer.trim();
    if (a.isEmpty) return null;
    switch (field.kind) {
      case FormFieldKind.email:
        // One @ with something either side. Anything stricter starts
        // rejecting real addresses, which is worse than missing a typo.
        if (!RegExp(r'^[^@\s]+@[^@\s]+$').hasMatch(a)) {
          return 'That does not look like an email address.';
        }
        return null;
      case FormFieldKind.phone:
        if (a.replaceAll(RegExp(r'\D'), '').length < 6) {
          return 'That does not look like a phone number.';
        }
        return null;
      case FormFieldKind.number:
        // The answer is still never parsed for STORAGE — it stays text so a
        // leading zero survives. This parses only to COMPARE, and a value
        // that will not parse is left alone rather than called out: the
        // keyboard is numeric, and "that is not a number" is not a sentence
        // worth showing somebody looking at what they typed.
        final n = num.tryParse(a);
        if (n == null) return null;
        if (field.min != null && n < field.min!) {
          return field.max != null
              ? 'Enter a number between ${field.min} and ${field.max}.'
              : 'Enter ${field.min} or more.';
        }
        if (field.max != null && n > field.max!) {
          return field.min != null
              ? 'Enter a number between ${field.min} and ${field.max}.'
              : 'Enter ${field.max} or less.';
        }
        return null;
      default:
        return null;
    }
  }

  /// Whether [answers] satisfies [fields] — every required question that is
  /// actually being asked answered, and nothing answered in a shape the
  /// question refuses. Pure, so the send button and the receiving end can
  /// agree without either trusting the other.
  static bool isComplete(
      List<FormFieldSpec> fields, List<String> answers) {
    for (var i = 0; i < fields.length; i++) {
      if (!isShown(fields, answers, i)) continue;
      final answer = i < answers.length ? answers[i] : '';
      if (fields[i].required && answer.trim().isEmpty) return false;
      if (formatProblem(fields[i], answer) != null) return false;
    }
    return true;
  }

  /// How many people picked each value of question [q] — the sender's
  /// overview, so twelve answers to "Which days?" do not have to be read as
  /// twelve cards. Choose-many answers count once per pick. Only the values
  /// the question offers are counted (all of them, zeroes included, so an
  /// option nobody picked is a said zero rather than a missing row); an
  /// answer to a question the person was never shown is not an answer.
  static Map<String, int> tally(List<FormFieldSpec> fields,
      List<FormResponse> responses, int q) {
    if (q < 0 || q >= fields.length) return const {};
    final counts = {for (final v in fields[q].gateValues) v: 0};
    for (final r in responses) {
      if (!isShown(fields, r.answers, q)) continue;
      final answer = q < r.answers.length ? r.answers[q] : '';
      final picks = fields[q].kind == FormFieldKind.chooseMany
          ? answer.split(', ')
          : [answer];
      for (final pick in picks) {
        if (counts.containsKey(pick)) counts[pick] = counts[pick]! + 1;
      }
    }
    return counts;
  }

  /// The average of a rating question's stars, or null when nobody rated.
  static double? ratingAverage(List<FormFieldSpec> fields,
      List<FormResponse> responses, int q) {
    if (q < 0 ||
        q >= fields.length ||
        fields[q].kind != FormFieldKind.rating) {
      return null;
    }
    var sum = 0, n = 0;
    for (final r in responses) {
      if (!isShown(fields, r.answers, q)) continue;
      final answer = q < r.answers.length ? r.answers[q] : '';
      final stars = int.tryParse(answer.split('/').first);
      if (stars == null || stars < 1 || stars > 5) continue;
      sum += stars;
      n++;
    }
    return n == 0 ? null : sum / n;
  }
}
