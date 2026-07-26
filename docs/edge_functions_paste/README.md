# Deploy the payment functions with copy-paste (no CLI)

Each `.ts` file in this folder is a self-contained copy of one payment
Edge Function — same logic as `supabase/functions/`, with the shared helper
inlined so it can be pasted straight into the Supabase Dashboard editor.

## Steps (repeat for each of the four files)

1. Open **supabase.com/dashboard** → your project → **Edge Functions**.
2. Click **Deploy a new function** → **Via Editor**.
3. Set the function **name** to the file's name (exactly):
   - `payments-create-intent`
   - `payments-onboard`
   - `payments-status`
   - `payments-webhook`
4. Delete the sample code, paste the entire contents of the matching file
   from this folder, and click **Deploy function**.
5. **For `payments-webhook` only:** open the deployed function → Details →
   turn **off** "Enforce JWT verification". (Stripe calls it directly and
   authenticates with its own signature, not a Supabase login.)

## Then add the secrets

Edge Functions → **Secrets**:

| Secret | Value |
|---|---|
| `STRIPE_SECRET_KEY` | `sk_live_...` (Stripe → Developers → API keys) |
| `STRIPE_WEBHOOK_SECRET` | `whsec_...` (from the webhook endpoint below) |

Optional: `PLATFORM_FEE_PERCENT` (default 1.5), `PLATFORM_FEE_FIXED_CENTS`
(default 0), `APP_RETURN_URL`.

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
