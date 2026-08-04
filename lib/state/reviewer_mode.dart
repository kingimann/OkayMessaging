import 'session.dart';

/// The App Review / demo tester account, recognized by its phone number.
///
/// Apple's reviewer signs in with the Supabase TEST phone number (a fixed
/// OTP, docs/app_review.md) and then needs to see everything — but two
/// gates are impossible for a reviewer to pass honestly: the Stripe ID
/// check (they will not photograph their passport for a demo), and
/// anything that would move real money. So the reviewer account:
///
///  * passes [VerifiedGate] (wallet, marketplace selling, Okay Drop) as
///    if verified, and
///  * is PERMANENTLY in payments test mode — the sandbox that simulates
///    every flow with no Stripe call and no money. The toggle cannot turn
///    it off for this account, so a reviewer can never reach a real
///    charge even by exploring.
///
/// This unlocks nothing for anybody else: the numbers here are Supabase
/// test fixtures (the reserved +1 500 555 01xx range — never real
/// phones), and only the dashboard's fixed-OTP entry lets anyone sign
/// into them.
class ReviewerMode {
  ReviewerMode._();

  /// Digits of the accounts treated as reviewer/demo. Must match the test
  /// phone numbers configured in Supabase → Authentication → Phone.
  static const Set<String> reviewerDigits = {'15005550006'};

  static String _digits(String phone) => phone.replaceAll(RegExp(r'\D'), '');

  /// Whether the signed-in account is the reviewer/demo account.
  static bool get active {
    final phone = Session.instance.user.value?.phone;
    return phone != null && reviewerDigits.contains(_digits(phone));
  }
}
