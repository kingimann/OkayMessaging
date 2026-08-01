# Deploy the Edge Functions with copy-paste (no CLI)

Each `.ts` file here is a self-contained copy of one Edge Function — same
logic as `supabase/functions/`, with the shared helper inlined where one was
needed, so it pastes straight into the Supabase Dashboard editor.

## First, the setting that silently breaks two of them

**`payments-webhook` and `iap-notify` must have "Enforce JWT verification"
OFF.** Everything else here keeps it on.

Stripe and Apple do not log in. They authenticate by signing the request body,
which both functions verify themselves. Supabase checks a JWT at the *gateway*,
before the function runs, so with the setting on every delivery is answered:

```json
{"code":"UNAUTHORIZED_NO_AUTH_HEADER","message":"Missing authorization header"}
```

**Nothing is logged when this happens** — the function never executes, so
there is nothing to see in its logs, and the deployment looks healthy. It
surfaced once as a "Stripe webhook delivery issues" email a week later, after
38 dropped events and four days before Stripe would have disabled the
endpoint. `iap-notify` failing the same way is quieter still: a subscription
renews, Apple's notice is refused, and the entitlement silently stops.

Check both from anywhere, with **no** auth header — that is what the two
senders do:

```bash
for f in payments-webhook iap-notify; do
  curl -s -o /dev/null -w "$f %{http_code}\n" -X POST \
    https://trbdqucphtsstnrwwfnw.supabase.co/functions/v1/$f \
    -H "Content-Type: application/json" -d '{}'
done
```

**400 is correct** — the function ran and refused an unsigned body. **401**
means the toggle is still on. **404** means it is not deployed.

The repo records the requirement in `supabase/config.toml`, which
`supabase functions deploy` reads — but **the dashboard does not**, so a
paste deploy leaves the toggle at its default and it has to be turned off by
hand each time: open the function → Details → turn off "Enforce JWT
verification".

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

**Both Stripe keys must be in the same mode.** A live publishable key cannot
authenticate an Account Session minted by a test secret key, and Stripe's only
symptom is *"An error occurred while authenticating your account. Please try
again."* — which reads like a problem with the account rather than with the
keys. `payments-account-session` now returns `livemode`, and the app refuses to
open the page with a message naming which half is wrong.

The page holds no client secret of its own: `fetchClientSecret` asks the app,
which calls `payments-account-session` again. Stripe re-invokes that callback
when a session expires and requires a **new** session each time, so a cached
secret authenticates once and then fails with the same message, leaving the
component spinning.

`payments-onboard` stays deployed as the fallback for the web build, which has
no WebView.

## In-app ID check (the blue check)

The verification runs inside the app too. `identity-start` returns the
VerificationSession's `client_secret`, `web/identity.html` calls Stripe.js
`verifyIdentity()`, and the same WebView hosts it — with camera permission
granted up front, since the user already agreed on the previous screen.

The documents and the selfie go to Stripe and are never seen, uploaded, or
stored by this app. The verdict arrives by webhook and the app re-reads it;
the screen never grants the badge itself.

Re-deploy `identity-start` for the client secret. `IDENTITY_PAGE_URL` and
`CONNECT_PAGE_URL` are `--dart-define`s that default to the project's Pages
deployment, so they only need setting if the web build moves.

## Who may send money

Two gates, both enforced server-side — a rule the app enforces is a rule a
modified app can skip.

**Before a charge is created** (`payments-create-intent`):

- The sender's phone is verified already: `callerPhone` comes from a Supabase
  session whose JWT carries an SMS-verified number.
- Their identity must be `verified` in `identity_verifications`, and must have
  a `verified_name`. No name means nothing to check a card against, and that
  fails closed.

Otherwise the call returns `identity_required` (403).

**Before the money is taken** (`payment_intent.amount_capturable_updated`):

The intent is created with `capture_method: "manual"`, so the card is
authorised but not charged. Once a card is attached, the webhook judges it:

| Rule | Failure |
|---|---|
| Not a prepaid card | `blocked_prepaid` |
| Cardholder name matches the name on the sender's ID | `blocked_name_mismatch` |
| Card readable at all | `blocked_unknown_card` |

A card that passes is captured; one that fails is **cancelled**, which
releases the hold — the sender is never charged. Checking after capture would
be a refund, not a check.

Name matching is deliberately lenient one way and strict the other: cards
print names abbreviated and reordered ("SMITH ROBERT J", "Rob Smith"), so the
surname must appear and the given name must match or abbreviate. A different
person's name shares neither. Run the cases with:

```bash
node --experimental-strip-types supabase/functions/_shared/cardholder_test.mjs
```

**Deploy for this:** run `docs/identity_name_match.sql`, re-paste
`payments-create-intent` and `payments-webhook`, and deploy
`payments-intent-status`. Subscribe the webhook to
`payment_intent.amount_capturable_updated` as well.

## Payment controls and history

Run `docs/payment_controls.sql`, then deploy `payments-history` and
`payments-settings` (JWT verification **on** for both).

| Control | Where it lives | Enforced |
|---|---|---|
| Pause everything, both directions | `payment_settings.paused` | `payments-create-intent` |
| Who may pay you (`anyone` / `nobody`) | `payment_settings` | `payments-create-intent` |
| Blocked senders | `payment_blocks` | `payments-create-intent` |
| Most in one transfer (default: no cap) | `payment_settings.max_send_cents` | `payments-create-intent` |
| Daily send cap (default $500) | `payment_settings` | `payments-create-intent` |

All of them are checked before a charge exists. A limit the app applies is a
limit a modified app ignores, and a limit matters most when something has
already gone wrong.

Blocked and failed charges are excluded from the daily total — money that
never moved must not use up someone's day.

**Raising a limit waits 24 hours; lowering one is immediate.** Without that
the caps stop nothing they were written to stop: whoever is holding an
unlocked phone holds the session too, so they can raise the day to its ceiling
and then send. The waiting raise lives in the `pending_*` columns and is
applied on the first read after its moment passes — no job runs. The rule is
`_shared/payment_limits.ts`, and `payment_limits_test.mjs` executes every
branch of it (`sh tool/check_functions.sh`).

Zero means *no cap* for both limits, not "nothing may be sent" — so lifting a
cap is a loosening, and waits like any other.

`payments-history` returns both directions from `payment_transactions`, which
is where the whole picture lives: a transfer has two sides and only one of
them is any given phone.
