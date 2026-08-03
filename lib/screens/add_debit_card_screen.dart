import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../payments/connect_fields.dart';
import '../payments/payment_service.dart';
import '../payments/stripe_tokens.dart';
import '../theme/app_theme.dart';

/// Attaching the debit card instant payouts land on.
///
/// The app's own form, same promise as the bank details: the number is
/// tokenised straight from this device to Stripe, so even this app's server
/// only ever sees `tok_…` and never a card number. This screen used to not
/// exist at all — "Add a debit card" opened Payment controls, which has no
/// card in it anywhere.
class AddDebitCardScreen extends StatefulWidget {
  /// The connected account's payout currency ('cad', 'usd').
  final String currency;
  const AddDebitCardScreen({super.key, this.currency = 'cad'});

  @override
  State<AddDebitCardScreen> createState() => _AddDebitCardScreenState();
}

class _AddDebitCardScreenState extends State<AddDebitCardScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _number = TextEditingController();
  final _month = TextEditingController();
  final _year = TextEditingController();
  final _cvc = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _number.dispose();
    _month.dispose();
    _year.dispose();
    _cvc.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      if (PaymentService.instance.testMode.value) {
        // Simulated like every other payment surface: no store, no Stripe,
        // and nothing invented onto a real account.
        await Future<void>.delayed(const Duration(milliseconds: 900));
        if (mounted) Navigator.of(context).pop(true);
        return;
      }
      // Device → Stripe, nothing in between.
      final token = await StripeTokens.debitCard(
        number: ConnectValidation.digitsOf(_number.text),
        expMonth: int.parse(ConnectValidation.digitsOf(_month.text)),
        expYear: int.parse(ConnectValidation.digitsOf(_year.text)),
        cvc: ConnectValidation.digitsOf(_cvc.text),
        currency: widget.currency,
        name: _name.text.trim(),
      );
      // The server attaches the token to the connected account — the same
      // door the bank token goes through.
      await PaymentService.instance
          .connectRequirements(submit: {'cardToken': token});
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      final raw = '$e'
          .replaceFirst('PaymentException: ', '')
          .replaceFirst('StripeTokenException: ', '');
      setState(() {
        _submitting = false;
        _error = switch (raw) {
          'card_changes_locked' =>
            'The card on this account has changed too often, so adding '
                'another is locked. The lock lifts on its own once the '
                'recent changes are more than 30 days old.',
          'card_name_mismatch' =>
            'The name on the card has to match the name on your verified '
                'ID. A card in somebody else\'s name can\'t be used here.',
          'card_prepaid' =>
            'Prepaid cards can\'t receive instant payouts — use a debit '
                'card attached to your bank account.',
          'identity_required' =>
            'Verify your ID first — Settings → Get verified. The card is '
                'checked against the name on it.',
          _ => raw,
        };
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Add a debit card')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Instant payouts land on a debit card. The number goes '
              'straight to Stripe from this device — it never touches this '
              'app\'s server.',
              style:
                  TextStyle(color: AppColors.subtle(context), fontSize: 13.5),
            ),
            const SizedBox(height: 18),
            TextFormField(
              controller: _name,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              validator: (v) => ConnectValidation.name(v, 'name on the card'),
              decoration: const InputDecoration(
                labelText: 'Name on the card',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _number,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(19),
              ],
              validator: ConnectValidation.cardNumber,
              decoration: const InputDecoration(
                labelText: 'Card number',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _month,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(2),
                    ],
                    decoration: const InputDecoration(
                      labelText: 'MM',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextFormField(
                    controller: _year,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(4),
                    ],
                    decoration: const InputDecoration(
                      labelText: 'YY',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextFormField(
                    controller: _cvc,
                    keyboardType: TextInputType.number,
                    obscureText: true,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(4),
                    ],
                    validator: ConnectValidation.cardCvc,
                    decoration: const InputDecoration(
                      labelText: 'CVC',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
              ],
            ),
            // One message under the row rather than two identical ones in it,
            // same as the date of birth on the payments form.
            Builder(builder: (context) {
              final problem = ConnectValidation.cardExpiry(
                int.tryParse(ConnectValidation.digitsOf(_month.text)),
                int.tryParse(ConnectValidation.digitsOf(_year.text)),
                now: DateTime.now(),
              );
              return problem == null || _month.text.isEmpty
                  ? const SizedBox(height: 8)
                  : Padding(
                      padding: const EdgeInsets.only(top: 6, bottom: 8),
                      child: Text(problem,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                              fontSize: 12.5)),
                    );
            }),
            if (_error != null) ...[
              const SizedBox(height: 8),
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
                  : const Text('Add card'),
            ),
            const SizedBox(height: 10),
            Text(
              'It has to be a debit card in your own name — the name is '
              'checked against your verified ID, and prepaid or credit '
              'cards can\'t receive instant payouts. As a security measure, '
              'a newly added card also waits 7 business days before instant '
              'payouts can land on it.',
              style: TextStyle(fontSize: 12, color: AppColors.subtle(context)),
            ),
          ],
        ),
      ),
    );
  }
}
