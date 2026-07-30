import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../payments/connect_fields.dart';
import '../payments/payment_service.dart';
import '../payments/stripe_tokens.dart';
import '../util/photo_prep.dart';
import 'connect_onboarding_screen.dart';

/// Setting up payments in the app's own forms.
///
/// Everything on this screen is this app's: its fields, its keyboard, its
/// buttons, its colours. Nothing is a web page and nothing pops up. Stripe is
/// still the one holding the details — the bank number and the ID number are
/// tokenised straight to Stripe from the device, so even this app's server never
/// sees them — but the asking happens here.
///
/// It asks only for what Stripe says is missing. A requirement this app has no
/// form for is named rather than hidden, with the hosted flow offered for that
/// case alone, because a form that cannot finish the job is worse than saying so.
class NativeOnboardingScreen extends StatefulWidget {
  const NativeOnboardingScreen({super.key});

  @override
  State<NativeOnboardingScreen> createState() => _NativeOnboardingScreenState();
}

class _NativeOnboardingScreenState extends State<NativeOnboardingScreen> {
  final _form = GlobalKey<FormState>();

  ConnectRequirements? _req;
  String? _loadError;
  bool _submitting = false;
  String? _submitError;

  final _first = TextEditingController();
  final _last = TextEditingController();
  final _email = TextEditingController();
  final _line1 = TextEditingController();
  final _line2 = TextEditingController();
  final _city = TextEditingController();
  final _state = TextEditingController();
  final _postal = TextEditingController();
  final _day = TextEditingController();
  final _month = TextEditingController();
  final _year = TextEditingController();
  final _idNumber = TextEditingController();
  final _ssnLast4 = TextEditingController();
  final _holder = TextEditingController();
  final _transit = TextEditingController();
  final _institution = TextEditingController();
  final _routing = TextEditingController();
  final _account = TextEditingController();
  final _work = TextEditingController();
  bool _tos = false;

  /// The document photos, held as bytes until submission so nothing is uploaded
  /// for a form somebody then abandons.
  Uint8List? _docFront;
  Uint8List? _docBack;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [
      _first, _last, _email, _line1, _line2, _city, _state, _postal,
      _day, _month, _year, _idNumber, _ssnLast4, _holder, _transit,
      _institution, _routing, _account, _work,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loadError = null);
    try {
      final req = await PaymentService.instance.connectRequirements();
      if (!mounted) return;
      setState(() => _req = req);
    } catch (e) {
      if (!mounted) return;
      setState(() =>
          _loadError = '$e'.replaceFirst('PaymentException: ', ''));
    }
  }

  String get _country => _req?.country.toUpperCase() ?? 'CA';

  /// The routing number Stripe wants, assembled from what the form asked for.
  /// Canada prints the transit and institution numbers separately on a cheque,
  /// so the form asks for them that way and joins them here rather than making
  /// somebody work out the order.
  String get _routingForStripe => _country == 'CA'
      ? '${ConnectValidation.digitsOf(_transit.text)}'
          '${ConnectValidation.digitsOf(_institution.text)}'
      : ConnectValidation.digitsOf(_routing.text);

  Future<void> _submit() async {
    final req = _req;
    if (req == null) return;
    if (!(_form.currentState?.validate() ?? false)) return;
    final needs = req.fieldsNeeded;
    if (needs.contains(ConnectField.tos) && !_tos) {
      setState(() => _submitError = 'Accept Stripe\'s terms to continue.');
      return;
    }
    setState(() {
      _submitting = true;
      _submitError = null;
    });
    try {
      // Tokenised on the device: the raw numbers go to Stripe and to nowhere
      // else, including this app's own server.
      String? bankToken;
      if (needs.contains(ConnectField.bank)) {
        bankToken = await StripeTokens.bankAccount(
          country: _country,
          currency: req.currency.isEmpty
              ? (_country == 'CA' ? 'cad' : 'usd')
              : req.currency,
          accountHolderName: _holder.text.trim().isEmpty
              ? '${_first.text.trim()} ${_last.text.trim()}'.trim()
              : _holder.text.trim(),
          routingNumber: _routingForStripe,
          accountNumber: ConnectValidation.digitsOf(_account.text),
        );
      }
      // Straight from the camera to Stripe. Stripe's file endpoint takes the
      // publishable key over Bearer auth, so the photo of somebody's licence
      // goes to Stripe and nowhere else — this app's server sees only the id.
      String? frontId;
      String? backId;
      if (needs.contains(ConnectField.document)) {
        if (_docFront == null) {
          setState(() {
            _submitting = false;
            _submitError = 'Add a photo of your ID.';
          });
          return;
        }
        frontId = await StripeTokens.identityDocument(_docFront!,
            filename: 'id-front.jpg');
        if (_docBack != null) {
          backId = await StripeTokens.identityDocument(_docBack!,
              filename: 'id-back.jpg');
        }
      }
      String? idToken;
      if (needs.contains(ConnectField.idNumber)) {
        idToken = await StripeTokens.idNumber(
            ConnectValidation.digitsOf(_idNumber.text));
      }

      final submission = <String, dynamic>{
        if (needs.contains(ConnectField.name)) ...{
          'firstName': _first.text.trim(),
          'lastName': _last.text.trim(),
        },
        if (needs.contains(ConnectField.email)) 'email': _email.text.trim(),
        if (needs.contains(ConnectField.dob))
          'dob': {
            'day': int.parse(ConnectValidation.digitsOf(_day.text)),
            'month': int.parse(ConnectValidation.digitsOf(_month.text)),
            'year': int.parse(ConnectValidation.digitsOf(_year.text)),
          },
        if (needs.contains(ConnectField.address))
          'address': {
            'line1': _line1.text.trim(),
            if (_line2.text.trim().isNotEmpty) 'line2': _line2.text.trim(),
            'city': _city.text.trim(),
            'state': _state.text.trim(),
            'postalCode': _postal.text.trim().toUpperCase(),
            'country': _country,
          },
        if (idToken != null) 'idNumberToken': idToken,
        if (needs.contains(ConnectField.ssnLast4))
          'ssnLast4': ConnectValidation.digitsOf(_ssnLast4.text),
        if (bankToken != null) 'bankToken': bankToken,
        if (frontId != null) 'documentFrontFileId': frontId,
        if (backId != null) 'documentBackFileId': backId,
        if (needs.contains(ConnectField.business))
          'productDescription': _work.text.trim().isEmpty
              ? 'Peer-to-peer transfers between people who know each other'
              : _work.text.trim(),
        if (needs.contains(ConnectField.tos)) 'acceptedTos': true,
      };

      final after =
          await PaymentService.instance.connectRequirements(submit: submission);
      if (!mounted) return;
      if (after.complete || after.payoutsEnabled) {
        Navigator.of(context).pop(true);
        return;
      }
      // Stripe asks in rounds: satisfying one set can reveal another. Show what
      // is left rather than claiming to be finished.
      setState(() {
        _req = after;
        _submitting = false;
        _submitError = after.errors.isEmpty
            ? null
            : after.errors.map((e) => e.reason).join('\n');
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _submitError = '$e'.replaceFirst('PaymentException: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final req = _req;
    return Scaffold(
      appBar: AppBar(title: const Text('Set up payments')),
      body: _loadError != null
          ? _problem(_loadError!)
          : req == null
              ? const Center(child: CircularProgressIndicator())
              : !req.collectableInApp
                  ? _mustUseHosted(req)
                  : req.complete
                      ? _allDone()
                      : _fields(req),
    );
  }

  Widget _problem(String message) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              OutlinedButton(onPressed: _load, child: const Text('Try again')),
            ],
          ),
        ),
      );

  /// An account made before native collection existed. Stripe will not let this
  /// app collect its details, so saying so and offering the page that can is
  /// the only honest option.
  Widget _mustUseHosted(ConnectRequirements req) => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'This payment account was created before in-app setup existed, '
                'and Stripe only lets its details be collected on Stripe\'s own '
                'form.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 18),
              FilledButton(
                onPressed: () => Navigator.of(context).pushReplacement(
                    MaterialPageRoute(
                        builder: (_) => const ConnectOnboardingScreen())),
                child: const Text('Continue on Stripe'),
              ),
            ],
          ),
        ),
      );

  Widget _allDone() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.check_circle, color: Colors.green, size: 44),
              const SizedBox(height: 12),
              const Text('Payments are set up.', textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Done'),
              ),
            ],
          ),
        ),
      );

  Widget _fields(ConnectRequirements req) {
    final needs = req.fieldsNeeded;
    return Form(
      key: _form,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Text(
            'Stripe needs these to pay you out. They go straight to Stripe — '
            'your bank number and ID number are sent to Stripe from this '
            'device and never through this app\'s server.',
            style: TextStyle(color: Colors.grey.shade600, fontSize: 13.5),
          ),
          // An empty half-made account was thrown away to get here. Said once,
          // because a payment account quietly changing underneath somebody is
          // the kind of thing they should hear from us and not notice later.
          if (req.replacedStaleAccount) ...[
            const SizedBox(height: 10),
            Text(
              'An unfinished payment account from an earlier attempt was '
              'discarded — it had nothing in it — so this can be completed '
              'here instead of on Stripe\'s website.',
              style: TextStyle(fontSize: 12.5, color: Colors.grey.shade600),
            ),
          ],
          const SizedBox(height: 18),
          if (needs.contains(ConnectField.name)) ...[
            _section('Your name'),
            _text(_first, 'First name',
                validator: (v) => ConnectValidation.name(v, 'first name')),
            _text(_last, 'Last name',
                validator: (v) => ConnectValidation.name(v, 'last name')),
          ],
          if (needs.contains(ConnectField.email)) ...[
            _section('Email'),
            _text(_email, 'Email',
                keyboard: TextInputType.emailAddress,
                validator: ConnectValidation.email),
          ],
          if (needs.contains(ConnectField.dob)) ...[
            _section('Date of birth'),
            Row(
              children: [
                Expanded(child: _text(_day, 'Day', digitsOnly: true, max: 2)),
                const SizedBox(width: 10),
                Expanded(
                    child: _text(_month, 'Month', digitsOnly: true, max: 2)),
                const SizedBox(width: 10),
                Expanded(child: _text(_year, 'Year', digitsOnly: true, max: 4)),
              ],
            ),
            // One message under the row rather than three identical ones in it.
            Builder(builder: (context) {
              final problem = ConnectValidation.dob(
                int.tryParse(ConnectValidation.digitsOf(_day.text)),
                int.tryParse(ConnectValidation.digitsOf(_month.text)),
                int.tryParse(ConnectValidation.digitsOf(_year.text)),
                now: DateTime.now(),
              );
              return problem == null || _day.text.isEmpty
                  ? const SizedBox(height: 8)
                  : Padding(
                      padding: const EdgeInsets.only(top: 6, bottom: 8),
                      child: Text(problem,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                              fontSize: 12.5)),
                    );
            }),
          ],
          if (needs.contains(ConnectField.address)) ...[
            _section('Your address'),
            _text(_line1, 'Street address',
                validator: (v) => ConnectValidation.name(v, 'address')),
            _text(_line2, 'Apartment, suite (optional)'),
            _text(_city, 'City',
                validator: (v) => ConnectValidation.name(v, 'city')),
            _text(_state, _country == 'CA' ? 'Province' : 'State',
                validator: (v) => ConnectValidation.name(
                    v, _country == 'CA' ? 'province' : 'state')),
            _text(_postal, _country == 'CA' ? 'Postal code' : 'ZIP code',
                validator: (v) =>
                    ConnectValidation.postalCode(v, _country)),
          ],
          if (needs.contains(ConnectField.idNumber)) ...[
            _section(_country == 'CA'
                ? 'Social Insurance Number'
                : 'Social Security Number'),
            _text(_idNumber, _country == 'CA' ? 'SIN' : 'SSN',
                digitsOnly: true,
                max: 11,
                validator: (v) => ConnectValidation.idNumber(v, _country)),
            Text(
              'Sent straight to Stripe from this device. This app\'s server '
              'never receives it.',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          ],
          if (needs.contains(ConnectField.ssnLast4)) ...[
            _section('Last 4 of your SSN'),
            _text(_ssnLast4, 'Last 4 digits',
                digitsOnly: true,
                max: 4,
                validator: ConnectValidation.ssnLast4),
          ],
          if (needs.contains(ConnectField.bank)) ...[
            _section('Where to pay you'),
            _text(_holder, 'Name on the account'),
            if (_country == 'CA') ...[
              Row(
                children: [
                  Expanded(
                    child: _text(_transit, 'Transit no. (5)',
                        digitsOnly: true,
                        max: 5,
                        validator: (v) =>
                            ConnectValidation.digitsOf(v ?? '').length == 5
                                ? null
                                : '5 digits'),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _text(_institution, 'Institution (3)',
                        digitsOnly: true,
                        max: 3,
                        validator: (v) =>
                            ConnectValidation.digitsOf(v ?? '').length == 3
                                ? null
                                : '3 digits'),
                  ),
                ],
              ),
            ] else
              _text(_routing, 'Routing number',
                  digitsOnly: true,
                  max: 9,
                  validator: (v) =>
                      ConnectValidation.routingNumber(v, _country)),
            _text(_account, 'Account number',
                digitsOnly: true,
                max: 17,
                validator: (v) =>
                    ConnectValidation.accountNumber(v, _country)),
          ],
          if (needs.contains(ConnectField.document)) ...[
            _section('Photo ID'),
            Text(
              'A driving licence or passport. Sent from this device straight to '
              'Stripe — this app\'s server never receives the image.',
              style: TextStyle(fontSize: 12.5, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _docButton('Front', _docFront,
                      (b) => setState(() => _docFront = b)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _docButton('Back (if it has one)', _docBack,
                      (b) => setState(() => _docBack = b)),
                ),
              ],
            ),
          ],
          if (needs.contains(ConnectField.business)) ...[
            _section('What the money is for'),
            _text(_work, 'e.g. paying friends back'),
          ],
          if (needs.contains(ConnectField.tos)) ...[
            const SizedBox(height: 8),
            CheckboxListTile(
              value: _tos,
              onChanged: (v) => setState(() => _tos = v ?? false),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'I accept Stripe\'s Connected Account Agreement.',
                style: TextStyle(fontSize: 13.5),
              ),
            ),
          ],
          // Named, not hidden. A requirement with no form here means the account
          // cannot finish activating through this screen, and pretending
          // otherwise wastes somebody's afternoon.
          if (req.unhandled.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              'Stripe also wants: ${req.unhandled.join(', ')}. That part isn\'t '
              'in this form yet — finish here, then use Stripe\'s own page for '
              'the rest.',
              style: TextStyle(fontSize: 12.5, color: Colors.orange.shade800),
            ),
          ],
          if (_submitError != null) ...[
            const SizedBox(height: 14),
            Text(_submitError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: 22),
          FilledButton(
            onPressed: _submitting ? null : _submit,
            child: _submitting
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Submit to Stripe'),
          ),
        ],
      ),
    );
  }

  /// One document photo. Shows a thumbnail once picked, because "did that
  /// actually attach?" is the question this kind of button always raises.
  Widget _docButton(
          String label, Uint8List? picked, ValueChanged<Uint8List?> onPicked) =>
      OutlinedButton(
        onPressed: () async {
          try {
            final bytes = await PhotoPrep.pickBytes();
            if (bytes != null) onPicked(bytes);
          } catch (e) {
            if (mounted) setState(() => _submitError = '\$e');
          }
        },
        style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 12)),
        child: picked == null
            ? Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.photo_camera_outlined, size: 18),
                  const SizedBox(width: 8),
                  Flexible(
                      child: Text(label,
                          maxLines: 1, overflow: TextOverflow.ellipsis)),
                ],
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Image.memory(picked,
                        width: 28, height: 28, fit: BoxFit.cover),
                  ),
                  const SizedBox(width: 8),
                  const Text('Change'),
                ],
              ),
      );

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 6),
        child: Text(title.toUpperCase(),
            style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.7)),
      );

  Widget _text(
    TextEditingController controller,
    String label, {
    String? Function(String?)? validator,
    TextInputType? keyboard,
    bool digitsOnly = false,
    int? max,
  }) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextFormField(
          controller: controller,
          validator: validator,
          keyboardType:
              digitsOnly ? TextInputType.number : (keyboard ?? TextInputType.text),
          inputFormatters: [
            if (digitsOnly) FilteringTextInputFormatter.digitsOnly,
            if (max != null) LengthLimitingTextInputFormatter(max),
          ],
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
      );
}
