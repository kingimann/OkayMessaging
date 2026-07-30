/// What Stripe still needs from a recipient, and whether this app can ask for
/// it in its own forms.
///
/// The rules here are pure so they can be tested without a network and without
/// Stripe: which requirement maps to which part of the form, what counts as a
/// valid date of birth, what a Canadian or American bank number looks like.
/// Getting those wrong means a form that submits and is rejected, which is the
/// worst outcome for the person filling it in.
library;

/// A section of the app's own onboarding form.
enum ConnectField {
  name,
  dob,
  address,
  email,
  phone,
  idNumber,
  ssnLast4,
  bank,
  document,
  tos,
  business,
}

/// Stripe's requirement strings, mapped to the form section that collects them.
///
/// Anything not in here is reported as unhandled rather than ignored: a
/// requirement nobody collects is an account that never activates, and the
/// person deserves to be told which one rather than left wondering.
const Map<String, ConnectField> stripeRequirementFields = {
  'individual.first_name': ConnectField.name,
  'individual.last_name': ConnectField.name,
  'individual.dob.day': ConnectField.dob,
  'individual.dob.month': ConnectField.dob,
  'individual.dob.year': ConnectField.dob,
  'individual.address.line1': ConnectField.address,
  'individual.address.line2': ConnectField.address,
  'individual.address.city': ConnectField.address,
  'individual.address.state': ConnectField.address,
  'individual.address.postal_code': ConnectField.address,
  'individual.address.country': ConnectField.address,
  'individual.email': ConnectField.email,
  'individual.phone': ConnectField.phone,
  'individual.id_number': ConnectField.idNumber,
  'individual.ssn_last_4': ConnectField.ssnLast4,
  'external_account': ConnectField.bank,
  'individual.verification.document': ConnectField.document,
  'individual.verification.additional_document': ConnectField.document,
  'tos_acceptance.date': ConnectField.tos,
  'tos_acceptance.ip': ConnectField.tos,
  'business_profile.mcc': ConnectField.business,
  'business_profile.product_description': ConnectField.business,
  'business_profile.url': ConnectField.business,
  'business_type': ConnectField.business,
};

/// One thing Stripe rejected, in its own words.
class RequirementError {
  final String requirement;
  final String reason;
  const RequirementError(this.requirement, this.reason);
}

/// The state of a recipient's Stripe account: what is missing, and whether the
/// app may collect it.
class ConnectRequirements {
  final String accountId;

  /// 'application' when this app collects the requirements — which is what
  /// makes the native form usable. 'stripe' means an older Express account that
  /// only Stripe's own pages can onboard.
  final String collection;

  final List<String> currentlyDue;
  final List<String> pastDue;

  /// Requirements with no form in this app. Named rather than hidden.
  final List<String> unhandled;

  final List<RequirementError> errors;
  final bool chargesEnabled;
  final bool payoutsEnabled;
  final bool detailsSubmitted;
  final String? disabledReason;
  final String country;
  final String currency;

  const ConnectRequirements({
    required this.accountId,
    required this.collection,
    required this.currentlyDue,
    required this.pastDue,
    required this.unhandled,
    required this.errors,
    required this.chargesEnabled,
    required this.payoutsEnabled,
    required this.detailsSubmitted,
    required this.disabledReason,
    required this.country,
    required this.currency,
  });

  factory ConnectRequirements.fromJson(Map<String, dynamic> j) {
    final status = (j['status'] as Map?)?.cast<String, dynamic>() ?? {};
    List<String> strings(Object? raw) =>
        [for (final v in (raw as List? ?? const [])) '$v'];
    return ConnectRequirements(
      accountId: j['accountId'] as String? ?? '',
      collection: j['collection'] as String? ?? 'stripe',
      currentlyDue: strings(j['currentlyDue']),
      pastDue: strings(j['pastDue']),
      unhandled: strings(j['unhandled']),
      errors: [
        for (final e in (j['errors'] as List? ?? const []))
          if (e is Map)
            RequirementError(
                '${e['requirement'] ?? ''}', '${e['reason'] ?? ''}')
      ],
      chargesEnabled: status['chargesEnabled'] == true,
      payoutsEnabled: status['payoutsEnabled'] == true,
      detailsSubmitted: status['detailsSubmitted'] == true,
      disabledReason: status['disabledReason'] as String?,
      country: j['country'] as String? ?? '',
      currency: j['currency'] as String? ?? '',
    );
  }

  /// Whether the app's own form can be used at all.
  bool get collectableInApp => collection == 'application';

  /// Nothing left to ask for.
  bool get complete => currentlyDue.isEmpty && pastDue.isEmpty;

  /// The form sections still needed, in the order they are asked.
  List<ConnectField> get fieldsNeeded {
    final wanted = <ConnectField>{};
    for (final r in [...pastDue, ...currentlyDue]) {
      final field = stripeRequirementFields[r];
      if (field != null) wanted.add(field);
    }
    return [for (final f in ConnectField.values) if (wanted.contains(f)) f];
  }
}

/// Validation for the app's own onboarding form. Pure.
///
/// Every rule here exists so a submission is rejected on the device, with the
/// field highlighted, rather than by Stripe after the fact — a Stripe rejection
/// arrives as a requirement error against a field name and reads like a fault.
class ConnectValidation {
  ConnectValidation._();

  /// Stripe asks a connected account's country for the bank details it wants,
  /// so a country this app has no rules for must be refused rather than
  /// guessed at.
  static const Set<String> supportedCountries = {'CA', 'US'};

  static String? name(String? value, String what) {
    final v = (value ?? '').trim();
    if (v.isEmpty) return 'Enter your $what.';
    if (v.length < 2) return 'That $what looks too short.';
    return null;
  }

  static String? email(String? value) {
    final v = (value ?? '').trim();
    if (v.isEmpty) return 'Enter your email.';
    // Deliberately loose: the only authority on whether an address works is
    // whether mail arrives, and an over-strict pattern rejects real addresses.
    if (!RegExp(r'^[^@\s]+@[^@\s.]+\.[^@\s]+$').hasMatch(v)) {
      return 'That email doesn\'t look right.';
    }
    return null;
  }

  /// A date of birth Stripe will accept, and a person old enough to hold an
  /// account. [now] is passed in so the rule is testable rather than
  /// time-dependent.
  static String? dob(int? day, int? month, int? year, {required DateTime now}) {
    if (day == null || month == null || year == null) {
      return 'Enter your date of birth.';
    }
    if (month < 1 || month > 12) return 'That month isn\'t valid.';
    if (day < 1 || day > 31) return 'That day isn\'t valid.';
    final date = DateTime(year, month, day);
    // Rolls over on an impossible date (31 February becomes 2 or 3 March), so
    // comparing back is how a real date is checked.
    if (date.year != year || date.month != month || date.day != day) {
      return 'That date doesn\'t exist.';
    }
    if (date.isAfter(now)) return 'That date is in the future.';
    var age = now.year - year;
    if (now.month < month || (now.month == month && now.day < day)) age--;
    if (age < 18) return 'You have to be 18 to receive payments.';
    if (age > 120) return 'Check the year.';
    return null;
  }

  static String? postalCode(String? value, String country) {
    final v = (value ?? '').trim().toUpperCase();
    if (v.isEmpty) return 'Enter your postal code.';
    return switch (country) {
      'CA' => RegExp(r'^[A-Z]\d[A-Z] ?\d[A-Z]\d$').hasMatch(v)
          ? null
          : 'A Canadian postal code looks like K1A 0B1.',
      'US' => RegExp(r'^\d{5}(-\d{4})?$').hasMatch(v)
          ? null
          : 'A ZIP code is five digits.',
      _ => null,
    };
  }

  /// Digits only, so a number typed with spaces or hyphens is accepted.
  static String digitsOf(String value) =>
      value.replaceAll(RegExp(r'[^0-9]'), '');

  /// The bank routing number, per country.
  ///
  /// Canada is the one worth spelling out: Stripe wants the transit number and
  /// the institution number together — five digits then three — which is not
  /// how a cheque prints them, so the form asks for both separately and this
  /// checks the join.
  static String? routingNumber(String? value, String country) {
    final d = digitsOf(value ?? '');
    if (d.isEmpty) return 'Enter your bank\'s routing number.';
    return switch (country) {
      'CA' => d.length == 8
          ? null
          : 'A Canadian routing number is 5 transit digits then 3 '
              'institution digits.',
      'US' => d.length == 9 ? null : 'A US routing number is 9 digits.',
      _ => null,
    };
  }

  static String? accountNumber(String? value, String country) {
    final d = digitsOf(value ?? '');
    if (d.isEmpty) return 'Enter your account number.';
    if (d.length < 4) return 'That account number looks too short.';
    if (d.length > 17) return 'That account number looks too long.';
    return null;
  }

  /// A government ID number, where Stripe asks for one. Canada uses a SIN,
  /// which is nine digits and has a check digit worth verifying — a typo caught
  /// here is a rejection avoided days later.
  static String? idNumber(String? value, String country) {
    final d = digitsOf(value ?? '');
    if (d.isEmpty) return 'Enter your number.';
    if (country == 'CA') {
      if (d.length != 9) return 'A SIN is nine digits.';
      if (!_luhnOk(d)) return 'Check that number — the digits don\'t add up.';
      return null;
    }
    if (country == 'US') {
      if (d.length != 9) return 'An SSN is nine digits.';
      return null;
    }
    return null;
  }

  static String? ssnLast4(String? value) {
    final d = digitsOf(value ?? '');
    if (d.length != 4) return 'Enter the last four digits.';
    return null;
  }

  /// The SIN check digit. Canada's numbers are Luhn-valid, so this catches a
  /// transposed pair, which is the commonest typo of all.
  static bool _luhnOk(String digits) {
    var sum = 0;
    for (var i = 0; i < digits.length; i++) {
      var n = digits.codeUnitAt(digits.length - 1 - i) - 48;
      if (i.isOdd) {
        n *= 2;
        if (n > 9) n -= 9;
      }
      sum += n;
    }
    return sum % 10 == 0;
  }
}
