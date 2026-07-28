# In-app purchases (Apple / Google)

Cloud storage and developer tips are **digital goods**, so App Store rules
require them to bill through the platform store (StoreKit / Play Billing), not
Stripe. Stripe stays only for peer-to-peer money transfers between users.

The app is wired for this (`lib/payments/store_purchases.dart` →
`lib/payments/apple_iap*.dart`). It stays inert until you create the products
below and enable the capability — until then purchases return "cancelled" and
nothing is charged. **Payments test mode** (Wallet settings) simulates the
whole flow with no store and no charge, so you can exercise the UI anywhere.

## Products to create

### Auto-renewable subscriptions — cloud storage
Users pick how much space they want with a slider. Apple only sells fixed
price points, so each step on that slider is its own product. In App Store
Connect → your app → Subscriptions, create one group ("Cloud storage")
containing all ten (prices from `docs/storage_economics.md`, ~$0.20/GB):

| Product ID | Size | Price |
|---|---|---|
| `com.okaymessaging.storage.gb10.monthly` | 10 GB | $1.99 / mo |
| `com.okaymessaging.storage.gb20.monthly` | 20 GB | $3.99 / mo |
| `com.okaymessaging.storage.gb30.monthly` | 30 GB | $5.99 / mo |
| `com.okaymessaging.storage.gb40.monthly` | 40 GB | $7.99 / mo |
| `com.okaymessaging.storage.gb50.monthly` | 50 GB | $9.99 / mo |
| `com.okaymessaging.storage.gb60.monthly` | 60 GB | $11.99 / mo |
| `com.okaymessaging.storage.gb70.monthly` | 70 GB | $13.99 / mo |
| `com.okaymessaging.storage.gb80.monthly` | 80 GB | $15.99 / mo |
| `com.okaymessaging.storage.gb90.monthly` | 90 GB | $17.99 / mo |
| `com.okaymessaging.storage.gb100.monthly` | 100 GB | $19.99 / mo |

Put them all in the **same subscription group** so switching size is an
upgrade/downgrade (Apple prorates automatically) rather than a second
concurrent subscription. Sizes above 100 GB are deliberately not offered.

### Consumables — developer tips
In App Store Connect → In-App Purchases, create four consumables:

| Product ID | Tip | Price |
|---|---|---|
| `com.okaymessaging.tip.coffee` | Coffee | $2.99 |
| `com.okaymessaging.tip.snack` | Snack | $5.99 |
| `com.okaymessaging.tip.lunch` | Lunch | $10.99 |
| `com.okaymessaging.tip.generous` | Generous | $24.99 |

The prices the app shows are the amounts above; the amount actually charged is
whatever you set on the product in App Store Connect, so keep them in sync (or
have the app read the store's localized price — say the word and I'll switch
the labels to the live store price).

## Enable the capability

1. In the Apple developer portal, add the **In-App Purchase** capability to the
   `com.okaymessaging` App ID (same visit as the Push / Default Messaging
   toggles), and delete the stale provisioning profile so Codemagic mints a
   fresh one.
2. Fill in the tax/banking "Agreements" in App Store Connect — IAP products stay
   in "Missing Metadata"/unavailable until the Paid Apps agreement is active.
3. Test with a **sandbox tester** account on a real device (IAP doesn't work in
   the simulator).

## Notes

- **Renewal & management** happen in the user's App Store settings; the app
  doesn't (and can't) cancel a subscription for them — the Cloud storage
  screen's cancel just drops the local entitlement to Free.
- **Restoring purchases**: `AppleIap.restore()` is available; wire a "Restore
  purchases" button if you want reinstalls to recover an active sub without
  re-billing.
- **Server validation** (receipt verification) isn't set up — entitlement is
  currently client-trusted. If you later add server auth, validate receipts in
  an Edge Function before granting the tier.

## Auto-renewable subscriptions: the server half

Apple charges a subscription every month whether or not the app is ever
opened. The device therefore cannot decide who has paid — a local "+30 days"
drifts the first time Apple renews, cancels, or refunds something, and month
two would bill the customer while their storage quietly stopped working.

Three Edge Functions close that gap:

| Function | Called by | JWT verification |
|---|---|---|
| `iap-validate` | the app, right after a purchase or restore | **on** |
| `iap-notify` | Apple, whenever a subscription changes | **off** |
| `iap-status` | the app, on launch and when the storage screen opens | **on** |

`iap-notify` must have "Enforce JWT verification" turned **off** — Apple
authenticates with its own signature, not a Supabase login, exactly like
`payments-webhook`.

### No App Store Connect API key is needed

StoreKit 2 transactions and App Store Server Notifications V2 are both JWS
with Apple's full certificate chain in the header, so they verify offline.
`_shared/apple_jws.ts` pins Apple Root CA G3 **and** walks the chain — pinning
alone would prove nothing, since that root is public and anyone could staple
it onto a chain they forged.

### Setup

1. Run `docs/iap_subscriptions.sql` in the SQL editor.
2. Deploy `iap-validate`, `iap-notify`, `iap-status` (paste copies are in
   `docs/edge_functions_paste/`). Turn JWT verification off on `iap-notify`.
3. App Store Connect -> your app -> App Information -> **App Store Server
   Notifications**. Set BOTH URLs, production and sandbox, to:

   ```
   https://trbdqucphtsstnrwwfnw.supabase.co/functions/v1/iap-notify
   ```

   Choose **Version 2** notifications.

`APNS_BUNDLE_ID` doubles as the bundle id these functions check a receipt
against; it defaults to `com.okaymessaging` when unset.

### What each notification does

| Apple says | Row becomes | Access |
|---|---|---|
| `SUBSCRIBED`, `DID_RENEW`, `OFFER_REDEEMED` | `active` | yes, to the new expiry |
| `DID_CHANGE_RENEWAL_STATUS` / `AUTO_RENEW_DISABLED` | `canceled` | **yes, until the paid period ends** |
| `DID_FAIL_TO_RENEW` / `GRACE_PERIOD` | `grace` | yes, to the grace expiry |
| `DID_FAIL_TO_RENEW` (no grace) | `expired` | no |
| `EXPIRED` | `expired` | no |
| `REFUND`, `REVOKE` | `refunded` | no, immediately |
| anything unrecognised | unchanged | unchanged |

Turning off auto-renew is not a cancellation of the current month — the user
paid for it and keeps it until it runs out. An unrecognised notification type
never revokes anything, because Apple adds new ones over time.

### Sandbox purchases do not grant storage by default

A sandbox purchase costs nothing, and Apple signs sandbox transactions with the
same certificate chain as real ones — so a sandbox receipt is cryptographically
indistinguishable from a paid one. Anyone able to run the app against a Sandbox
Apple ID would otherwise get 100 GB free.

Sandbox rows are therefore recorded but ignored when working out entitlement,
unless the Edge Function secret `IAP_ALLOW_SANDBOX` is set to `true`.

**Set it while testing. Take it off before release** — leaving it on is a free
storage plan for anyone who asks.

### Testing it

The helpers use only standard WebCrypto, so Node runs them without Deno:

```bash
node --experimental-strip-types supabase/functions/_shared/apple_jws_test.mjs
node --experimental-strip-types supabase/functions/_shared/iap_test.mjs
```

End to end, use a Sandbox Apple ID: sandbox subscriptions renew every few
minutes rather than monthly, so a renewal can be observed in `subscriptions`
within the hour.
