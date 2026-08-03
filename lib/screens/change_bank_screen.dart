import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../payments/connect_fields.dart';
import '../payments/payment_service.dart';
import '../payments/stripe_tokens.dart';
import '../theme/app_theme.dart';

/// Changing where the balance pays out — the direct deposit account.
///
/// The same promise as everywhere else money details appear: the numbers are
/// tokenised straight from this device to Stripe, and this app's server only
/// ever sees `btok_…`. Changing it is deliberately heavier than setting it
/// the first time: automatic payouts pause and nothing lands on the new
/// account for seven business days, because redirecting the payout account
/// is the other half of draining a taken-over wallet.
class ChangeBankScreen extends StatefulWidget {
  /// The connected account's country ('CA', 'US') and payout currency.
  final String country;
  final String currency;
  const ChangeBankScreen(
      {super.key, this.country = 'CA', this.currency = 'cad'});

  @override
  State<ChangeBankScreen> createState() => _ChangeBankScreenState();
}

class _ChangeBankScreenState extends State<ChangeBankScreen> {
  final _form = GlobalKey<FormState>();
  final _holder = TextEditingController();
  final _transit = TextEditingController();
  final _institution = TextEditingController();
  final _routing = TextEditingController();
  final _account = TextEditingController();
  bool _submitting = false;
  String? _error;

  String get _country => widget.country.toUpperCase();

  @override
  void dispose() {
    _holder.dispose();
    _transit.dispose();
    _institution.dispose();
    _routing.dispose();
    _account.dispose();
    super.dispose();
  }

  String get _routingForStripe => _country == 'CA'
      ? '${ConnectValidation.digitsOf(_transit.text)}'
          '${ConnectValidation.digitsOf(_institution.text)}'
      : ConnectValidation.digitsOf(_routing.text);

  Future<void> _submit() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      if (PaymentService.instance.testMode.value) {
        await Future<void>.delayed(const Duration(milliseconds: 900));
        if (mounted) Navigator.of(context).pop(true);
        return;
      }
      final token = await StripeTokens.bankAccount(
        country: _country,
        currency: widget.currency,
        accountHolderName: _holder.text.trim(),
        routingNumber: _routingForStripe,
        accountNumber: ConnectValidation.digitsOf(_account.text),
      );
      await PaymentService.instance
          .connectRequirements(submit: {'bankToken': token});
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      final raw = '$e'
          .replaceFirst('PaymentException: ', '')
          .replaceFirst('StripeTokenException: ', '');
      setState(() {
        _submitting = false;
        _error = raw == 'bank_changes_locked'
            ? 'The payout account has changed too often, so changing it '
                'again is locked. The lock lifts on its own once the recent '
                'changes are more than 30 days old.'
            : raw;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Change direct deposit')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Your balance pays out to this account. The numbers go '
              'straight to Stripe from this device — they never touch this '
              'app\'s server.',
              style:
                  TextStyle(color: AppColors.subtle(context), fontSize: 13.5),
            ),
            const SizedBox(height: 10),
            Text(
              'As a security measure, changing it pauses payouts: nothing '
              'lands on the new account for 7 business days.',
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: Colors.orange.shade800),
            ),
            const SizedBox(height: 18),
            TextFormField(
              controller: _holder,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              validator: (v) =>
                  ConnectValidation.name(v, 'name on the account'),
              decoration: const InputDecoration(
                labelText: 'Name on the account',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            if (_country == 'CA')
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _transit,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(5),
                      ],
                      validator: (v) =>
                          ConnectValidation.digitsOf(v ?? '').length == 5
                              ? null
                              : '5 digits',
                      decoration: const InputDecoration(
                        labelText: 'Transit no. (5)',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextFormField(
                      controller: _institution,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(3),
                      ],
                      validator: (v) =>
                          ConnectValidation.digitsOf(v ?? '').length == 3
                              ? null
                              : '3 digits',
                      decoration: const InputDecoration(
                        labelText: 'Institution (3)',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                ],
              )
            else
              TextFormField(
                controller: _routing,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(9),
                ],
                validator: (v) =>
                    ConnectValidation.routingNumber(v, _country),
                decoration: const InputDecoration(
                  labelText: 'Routing number',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _account,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(17),
              ],
              validator: (v) => ConnectValidation.accountNumber(v, _country),
              decoration: const InputDecoration(
                labelText: 'Account number',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _submitting ? null : _submit,
              child: _submitting
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Change payout account'),
            ),
          ],
        ),
      ),
    );
  }
}
