# Deploy the Edge Functions with copy-paste (no CLI)

Each `.ts` file here is a self-contained copy of one Edge Function — same
logic as `supabase/functions/`, with the shared helper inlined where one was
needed, so it pastes straight into the Supabase Dashboard editor.

## Steps (repeat for each of the five files)

1. Open **supabase.com/dashboard** → your project → **Edge Functions**.
2. Click **Deploy a new function** → **Via Editor**.
3. Set the function **name** to the file's name (exactly):
   - `payments-create-intent`
   - `payments-onboard`
   - `payments-status`
   - `payments-webhook`
   - `push-send`
4. Delete the sample code, paste the entire contents of the matching file
   from this folder, and click **Deploy function**.
5. **For `payments-webhook` only:** open the deployed function → Details →
   turn **off** "Enforce JWT verification". (Stripe calls it directly and
   authenticates with its own signature, not a Supabase login.) Leave it on
   for the other four.

Step 4 is the one that bites: deploying without replacing the sample leaves
Supabase's Hello World in place, and the function answers
`{"message":"Hello undefined!"}` instead of erroring. To check a deployment,
POST to it with nothing but the publishable key —

```bash
curl -s -X POST https://trbdqucphtsstnrwwfnw.supabase.co/functions/v1/<name> \
  -H "apikey: sb_publishable_PrY-Aru0AryWyhHgfD2Tow_uXca1owt" \
  -H "Content-Type: application/json" -d '{}'
```

The three JWT-protected payment functions should answer
`{"error":"unauthorized"}`, `push-send` the same, and `payments-webhook`
should complain about a missing `stripe-signature` header. A greeting means
the sample is still there.

## Then add the secrets

Edge Functions → **Secrets**:

| Secret | Value |
|---|---|
| `STRIPE_SECRET_KEY` | `sk_live_...` (Stripe → Developers → API keys) |
| `STRIPE_WEBHOOK_SECRET` | `whsec_...` (from the webhook endpoint below) |
| `APP_RETURN_URL` | where Stripe onboarding sends the user back to |
| `APNS_P8` | contents of the `.p8` auth key from developer.apple.com |
| `APNS_KEY_ID` | the key's 10-character id |
| `APNS_TEAM_ID` | your Apple team id |
| `APNS_BUNDLE_ID` | `com.okaymessaging` |
| `APNS_SANDBOX` | `true` while testing, `false` for App Store builds |

`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are injected automatically —
don't add them by hand.

Optional: `PLATFORM_FEE_PERCENT` (default 3.4) and `PLATFORM_FEE_FIXED_CENTS`
(default 10). These are the numbers `lib/payments/storage_economics.dart`
proves profitable against Stripe's 2.9% + 30¢; overriding them here without
changing the code puts the two out of sync, and only the code side is
test-covered. Anything lower loses money on small transfers.

## And the Stripe webhook

Stripe Dashboard → Developers → Webhooks → **Add endpoint**:

- URL: `https://trbdqucphtsstnrwwfnw.supabase.co/functions/v1/payments-webhook`
- Events: `payment_intent.succeeded`, `payment_intent.payment_failed`,
  `payment_intent.processing`, `account.updated`, `payout.created`,
  `payout.paid`, `payout.failed`, `payout.canceled`
- Copy its **Signing secret** into the `STRIPE_WEBHOOK_SECRET` secret above.

Finally, enable **Stripe Connect (Express)** once in Stripe → Settings →
Connect. Receivers onboard from the app's Wallet screen.

> Keep these paste files in sync: if `supabase/functions/` changes, regenerate
> or re-edit the copies here too.

## P2P payments: what has to be true before money moves

Deployed functions and secrets are not the whole story. Working through the
send path end to end, these also have to hold:

| | Where | Notes |
|---|---|---|
| Stripe Connect (Express) enabled | Stripe → Settings → Connect | Without it `payments-onboard` cannot create an account at all |
| Platform account activated | Stripe → Dashboard | A live `sk_` on an unactivated account can't take real charges |
| Receiver onboarded | in-app Wallet → onboarding | `payments-create-intent` returns `receiver_not_onboarded` until `charges_enabled` is true |
| `CONNECT_COUNTRY` | Edge Function secret, optional | Defaults to `CA`. Connected accounts are created in this country and it must match where the receiver banks |
| `APPLE_PAY_MERCHANT_ID` | `--dart-define` at build | Optional. Cards work without it; the Apple Pay button only appears when it is set, and it also needs a Merchant ID in the Apple portal plus the Apple Pay capability on the App ID |
| `PAYMENTS_COUNTRY` | `--dart-define` at build | Defaults to `CA`; the wallets' merchant country |

Only the sender needs the app; the receiver needs a completed Stripe
onboarding. Both need a signed-in session — every payment function resolves
the caller's verified phone from their Supabase JWT and 401s without one.

Payments are mobile-only: the Stripe Payment Sheet is native, so the web build
compiles a stub that reports unsupported.

## Direct charges: one extra webhook setting

Transfers are now **direct charges** — created on the recipient's connected
account so the platform never holds funds. Stripe fires `payment_intent.*`
events for those on the *connected account*, not the platform, so the webhook
endpoint must have **"Listen to events on Connected accounts"** turned on or
`payment_transactions` will never leave its initial status.

Also subscribe these, for the blue check:

```
identity.verification_session.verified
identity.verification_session.requires_input
identity.verification_session.processing
identity.verification_session.canceled
```

And run `docs/identity_verification.sql`, then deploy `identity-start` and
`identity-status` (JWT verification **on** for both).

## Chargeback bans

Run `docs/chargeback_bans.sql`, and subscribe the webhook to:

```
charge.dispute.created
```

A dispute bans the sender from sending money (enforced in
`payments-create-intent`, which then returns `sender_banned`). Lift a ban by
hand:

```sql
delete from public.payment_bans where phone = '15551234567';
```

Optionally set `STATEMENT_DESCRIPTOR` (defaults to `OKAYMSG`) so the charge is
recognisable on a card statement — unrecognised descriptors are a leading
cause of disputes.

## In-app onboarding (Connect embedded components)

Setting up payments no longer sends anyone to a browser. `payments-account-session`
returns an Account Session client secret, `web/connect.html` mounts Stripe's
`account-onboarding` component, and the app loads that page in a WebView inside
its own screen.

Deploy `payments-account-session` (JWT verification **on**) and, in the Stripe
dashboard, enable **Connect embedded components** if it is not already on.

Two Edge Function secrets matter here:

| Secret | Why |
|---|---|
| `STRIPE_PUBLISHABLE_KEY` | the embedded component needs it to initialise; the app falls back to its own compiled-in key if unset |
| `CONNECT_COUNTRY` | optional, defaults to `CA` |

`payments-onboard` stays deployed as the fallback for the web build, which has
no WebView.
