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
(default 35). These are the numbers `lib/payments/storage_economics.dart`
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
