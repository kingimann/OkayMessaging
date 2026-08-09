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

**23 products in total.**

### Three different numbers — do not expect them to be equal

This trips people up, so it is worth being blunt. A price exists in three
places, and only one of them is the truth:

| Where | What it is | Who sets it |
|---|---|---|
| **App Store Connect** | **What the buyer is actually charged.** The only real price. | you |
| The app's screens | Whatever StoreKit returned, in the buyer's own currency | Apple, at runtime |
| The USD column below | The app's built-in *fallback*, used only where there is no store price | this repo (+ the owner's Settings → Prices) |

So the table below **will not match what your phone shows** as soon as your
App Store Connect prices differ from these figures — and that is correct
behaviour, not drift. The app deliberately prefers Apple's price, because the
app's number is a guess and Apple's is the charge. If the two ever disagree
*on the same product in the same currency*, the app is wrong and worth
reporting; if the app simply shows your real CAD price where this table says
USD, everything is working.

Settings → **Prices** (owner-only) edits the fallback column live, for every
device, without a build — see `lib/state/pricing_store.dart`. It cannot
override a real store price. **Settings → Check store products** shows, per
product, the store's price next to the app's assumption, which is the fastest
way to see which of the three is out of step.

The USD column is that fallback. The CAD column is a suggestion, not Apple's
matrix: USD x1.4 rounded up to the next .99. Apple's picker only offers
certain price points, so take the nearest one it lists.

**The easiest way to avoid getting these out of order is to set the US price
and let Apple auto-generate every other storefront** (App Store Connect
offers this when you set a base price). Setting each storefront by hand is
what let the storage ladder go non-monotonic — see the rule below.

### Auto-renewable subscriptions — cloud storage
Users pick how much space they want with a slider. Apple only sells fixed
price points, so each step on that slider is its own product. In App Store
Connect → your app → Subscriptions, create one group ("Cloud storage")
containing all ten (prices from `docs/storage_economics.md`, ~$0.20/GB):

| Product ID | Size | USD / mo | CAD / mo |
|---|---|---|---|
| `com.okaymessaging.storage.gb10.monthly` | 10 GB | $1.99 | CA$2.99 |
| `com.okaymessaging.storage.gb20.monthly` | 20 GB | $3.99 | CA$5.99 |
| `com.okaymessaging.storage.gb30.monthly` | 30 GB | $5.99 | CA$8.99 |
| `com.okaymessaging.storage.gb40.monthly` | 40 GB | $7.99 | CA$11.99 |
| `com.okaymessaging.storage.gb50.monthly` | 50 GB | $9.99 | CA$13.99 |
| `com.okaymessaging.storage.gb60.monthly` | 60 GB | $11.99 | CA$16.99 |
| `com.okaymessaging.storage.gb70.monthly` | 70 GB | $13.99 | CA$19.99 |
| `com.okaymessaging.storage.gb80.monthly` | 80 GB | $15.99 | CA$22.99 |
| `com.okaymessaging.storage.gb90.monthly` | 90 GB | $17.99 | CA$25.99 |
| `com.okaymessaging.storage.gb100.monthly` | 100 GB | $19.99 | CA$27.99 |

Put them all in the **same subscription group** so switching size is an
upgrade/downgrade (Apple prorates automatically) rather than a second
concurrent subscription. Sizes above 100 GB are deliberately not offered.

**Two rules the storage ladder must obey, in every storefront:**

1. **Strictly increasing.** More space must cost more. A bigger plan priced
   below a smaller one reads as a broken app — and since the screen shows the
   store's real price (see below), App Store Connect is the only place that
   can break it. This actually happened: 70 GB was priced above 80, 90 and
   100 GB.
2. **Above the floor.** Break-even is **$0.095 USD per GB per month**
   (Supabase's bucket rate divided by Apple's 70% net — see
   `lib/payments/storage_economics.dart`). In CAD that floor is about
   **CA$0.13/GB**, so a 100 GB plan must stay above roughly CA$13. Every
   price in the table clears it with room to spare.

### Consumables — developer tips

| Product ID | Tip | USD | CAD |
|---|---|---|---|
| `com.okaymessaging.tip.coffee` | Coffee | $2.99 | CA$4.99 |
| `com.okaymessaging.tip.snack` | Snack | $5.99 | CA$8.99 |
| `com.okaymessaging.tip.lunch` | Lunch | $10.99 | CA$15.99 |
| `com.okaymessaging.tip.generous` | Generous | $24.99 | CA$34.99 |

Tips have no cost to cover, so these are free choices — only keep them in
increasing order.

### Consumables — creator subscriptions
One product per price tier (`AppUser.subscriptionTiersCents`). A creator picks
a tier; every tier unlocks the same subscribers-only posts.

| Product ID | Tier | USD / mo | CAD / mo |
|---|---|---|---|
| `com.okaymessaging.creatorsub.tier0.monthly` | 1 | $2.99 | CA$4.99 |
| `com.okaymessaging.creatorsub.tier1.monthly` | 2 | $4.99 | CA$6.99 |
| `com.okaymessaging.creatorsub.tier2.monthly` | 3 | $9.99 | CA$13.99 |
| `com.okaymessaging.creatorsub.tier3.monthly` | 4 | $19.99 | CA$27.99 |

### Consumables — paid server memberships
The membership twin of the above, a separate SKU family so a creator month and
a membership month can't be confused. **Same four prices.**

| Product ID | Tier | USD / mo | CAD / mo |
|---|---|---|---|
| `com.okaymessaging.communitysub.tier0.monthly` | 1 | $2.99 | CA$4.99 |
| `com.okaymessaging.communitysub.tier1.monthly` | 2 | $4.99 | CA$6.99 |
| `com.okaymessaging.communitysub.tier2.monthly` | 3 | $9.99 | CA$13.99 |
| `com.okaymessaging.communitysub.tier3.monthly` | 4 | $19.99 | CA$27.99 |

### Consumable — Okay AI unlimited pass

| Product ID | What | Price |
|---|---|---|
| `com.okaymessaging.okayai.pro.monthly` | 30 days of unlimited Okay AI | your call |

The only product with **no price in the app at all** — the upgrade sheet shows
no amount, so nothing can disagree with whatever App Store Connect charges.
Price it against the OpenRouter bill a heavy month runs up.

### The app shows the store's price, so changes need no rebuild

Every price on screen comes from StoreKit (`lib/payments/store_prices.dart`),
not from the numbers above — so a price changed in App Store Connect reaches
users without a new build, and a buyer always sees their own currency. The
cents in the code are only the fallback for web, payments-test mode, and the
moment before the store answers.

The catch is that **Apple's product metadata can lag a price change by hours**
(TestFlight worst of all), which showed as a card saying $1.99 beside a
purchase sheet charging $2.99. The purchase surfaces re-ask the store each
time they open and repaint when the answer lands, so the app converges as soon
as Apple does — but right after a price edit, expect a window where the old
figure is still what Apple is handing out.

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
