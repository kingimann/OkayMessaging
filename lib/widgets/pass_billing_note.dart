import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The billing disclosure for a 30-day pass — Okay AI Pro, a creator
/// subscription, or a paid server membership. All three are the same
/// mechanism under different names (see `StorePurchases`, which documents
/// each as a CONSUMABLE): a one-time charge that unlocks something for 30
/// days and then simply ends. None of them is an Apple auto-renewing
/// subscription — Apple would treat a second purchase of one auto-renewable
/// SKU as renewing the first, which cannot express "a month of THIS
/// creator" or "another 30 days of the assistant" once you already had one.
///
/// Cloud storage is the one product in this app that really auto-renews and
/// carries its own disclosure (`CloudSyncScreen._subscriptionDisclosure`,
/// required by App Review guideline 3.1.2 for a genuine subscription — do
/// not duplicate that widget here, the two are different legal shapes).
/// Every other purchase point in the app still read "Subscribe" and showed
/// "$X/mo" on its button, which is language a buyer reasonably reads as
/// auto-renewing while the product quietly is not — nothing short of saying
/// so plainly closes that gap, which is what this widget exists to do
/// wherever a 30-day pass is sold: the Store screen's Okay AI Pro card, the
/// in-chat upgrade sheet, the creator-subscribe sheet, and the paid-server
/// subscribe sheet.
class PassBillingNote extends StatelessWidget {
  const PassBillingNote({super.key});

  @override
  Widget build(BuildContext context) {
    final subtle = AppColors.subtle(context);
    return Text(
      'Charged once to your Apple ID when you confirm — this is NOT a '
      'recurring subscription. It unlocks for 30 days and then simply ends: '
      'nothing appears in Settings → Subscriptions for it, and nothing is '
      'charged again unless you come back here and buy another 30 days.',
      style: TextStyle(fontSize: 11.5, height: 1.4, color: subtle),
    );
  }
}
