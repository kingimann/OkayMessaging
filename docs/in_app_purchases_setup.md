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
