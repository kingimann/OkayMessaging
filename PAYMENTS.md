# In-chat payments (Stripe Connect Express)

Okay Messaging lets people send money to each other **inside a chat**. The
money-flow is built so **you never hold user funds** and don't become a
money-services business: funds move card → Stripe → the **receiver's** Stripe
Express connected-account balance → **automatic payout** to their Canadian
bank. You take an `application_fee` on each transaction; you never touch the
principal.

```
User A's card ──▶ Stripe ──▶ User B's connected-account balance ──▶ auto payout ──▶ B's bank
                    │
                    └── application_fee_amount ──▶ your platform account
```

- **No funds held by you / no FINTRAC MSB exposure** — destination charges send
  the money straight to the receiver's connected account.
- **No card numbers stored** — PCI is handled by Stripe; the app uses the native
  Payment Sheet.
- **Privacy preserved** — message content is never stored; only payment
  metadata (amounts, IDs, status) lives in the payment tables for routing and
  receipts.

## Architecture

| Piece | Where | Purpose |
|------|-------|---------|
| `payments-onboard` | Edge Function | Create Express account + KYC `account_link` |
| `payments-status` | Edge Function | Live balance, KYC flags, payout status |
| `payments-create-intent` | Edge Function | `PaymentIntent` with `transfer_data.destination` + `application_fee_amount` |
| `payments-webhook` | Edge Function | Sync payment / account / payout status |
| `payment_accounts`, `payment_transactions`, `payout_status` | Postgres | Routing + status metadata (service-role only) |
| `lib/payments/*` | Flutter | Service, native Payment Sheet, amount sheet, receipt bubble |
| `lib/screens/wallet_screen.dart` | Flutter | Receiver wallet: onboard, balance, cash-out |

The Stripe **secret** key lives only in the Edge Functions. The app ships only
the **publishable** key.

## One-time setup

### 1. Stripe
1. Create a Stripe account, enable **Connect** (Express).
2. Grab your keys: `pk_test_…` (publishable) and `sk_test_…` (secret).
3. Add a webhook endpoint (after deploying functions) pointing at
   `https://<project-ref>.functions.supabase.co/payments-webhook`, subscribing
   to: `payment_intent.succeeded`, `payment_intent.payment_failed`,
   `account.updated`, `payout.paid`, `payout.failed`. Copy its `whsec_…`.

### 2. Database
Run the payment tables at the bottom of `supabase/schema.sql` in the Supabase
SQL editor (idempotent; safe to re-run).

### 3. Deploy the Edge Functions
```sh
supabase functions deploy payments-onboard
supabase functions deploy payments-status
supabase functions deploy payments-create-intent
supabase functions deploy payments-webhook --no-verify-jwt   # Stripe signs it

supabase secrets set \
  STRIPE_SECRET_KEY=sk_test_... \
  STRIPE_WEBHOOK_SECRET=whsec_... \
  PLATFORM_FEE_PERCENT=1.5 \
  PLATFORM_FEE_FIXED_CENTS=0 \
  APP_RETURN_URL=okaymsg://payments/return
```

### 4. Build the app with your publishable key
```sh
flutter build appbundle --release \
  --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=... \
  --dart-define=STRIPE_PUBLISHABLE_KEY=pk_test_...
```
On Codemagic, add `STRIPE_PUBLISHABLE_KEY` to the `supabase` variable group and
it's threaded in automatically (see `codemagic.yaml`). Without the key, the
payments UI shows a friendly "not set up" state and stays inert.

## How it works in the app

- **Receiving money** — Settings → *Wallet & payments* → *Set up with Stripe*
  runs Express onboarding (`account_link`, the one Stripe-hosted step, opened in
  an in-app browser). After KYC, the wallet shows the balance and Stripe
  auto-pays out to the bank; the app just displays status from webhooks.
- **Sending money** — the chat's ➕ attach menu → *Payment* → enter an amount →
  the **native Payment Sheet** (card / Apple Pay / Google Pay, no Checkout
  redirect) confirms a destination `PaymentIntent`. On success a green payment
  receipt drops into the conversation and travels the encrypted relay to the
  recipient.
- If the recipient hasn't onboarded, sending is blocked with a clear message
  (`receiver_not_onboarded`).

## Platform notes
- **Android** — `MainActivity` extends `FlutterFragmentActivity` (required by
  `flutter_stripe`); `minSdk` is already 23.
- **iOS** — deployment target 13.0 (already set). For Apple Pay, add your
  merchant id in Xcode and set it in `stripe_sheet_native.dart`.
- **Web** — payments are mobile-only; a conditional import keeps the
  `flutter_stripe` SDK out of the web build, which shows "available in the
  mobile app".
