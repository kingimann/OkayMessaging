# Server deploy checklist

What is waiting on the Supabase dashboard, and what each item turns on. Work
top to bottom — SQL first, then functions.

**Everything here is safe to run twice.** Every table is `create table if not
exists`, every policy is preceded by `drop policy if exists`, the storage
bucket uses `on conflict do update`, and pasting a function again is just a
redeploy. If you can't remember whether you already did one, do it again.

---

## 1. SQL — six files, in this order

Dashboard → **SQL Editor** → paste the file → Run.

| # | File | Turns on | If you skip it |
|---|---|---|---|
| 1 | `docs/payment_controls.sql` | Transaction history, receive controls | History is empty; receive settings don't save |
| 2 | `docs/identity_directory_badge.sql` | Blue check visible to *other* people | Your badge shows only on your own device |
| 3 | `docs/directory_privacy.sql` | The "How people can reach you" switches | The switches say "Couldn't save" |
| 4 | `docs/market_media_bucket.sql` | Listing videos | Uploading a video says the bucket isn't provisioned |
| 5 | `docs/platform_moderation.sql` | App-wide roles, bans, suspensions, time-outs, reports | No Moderation section anywhere |
| 6 | `docs/public_feed.sql` | The public Newsfeed | The Newsfeed says it isn't set up |

### Then grant yourself the owner role

File 5 ends with this, commented out. Uncomment, put **your own** number in
(E.164 digits, no `+` or spaces), and run it:

```sql
insert into public.platform_roles (phone, role, granted_by)
values ('15551234567', 'owner', 'bootstrap')
on conflict (phone) do update set role = 'owner';
```

This is the only way to get a role. `platform_roles` has RLS on with no client
policy, so no app build can read or write who holds power — which is the point.
After running it, sign out and back in on your phone so a fresh JWT is issued,
then look in Settings for **Moderation**.

### ⚠️ One ordering trap

`supabase/schema.sql` defines the original `usernames_read` /
`usernames_insert_own` / `usernames_update_own` / `push_tokens_upsert_own`
policies. `platform_moderation.sql` **replaces** those with versions that hide
banned and suspended accounts.

So: run `platform_moderation.sql` **after** `schema.sql`, and if you ever
re-run `schema.sql`, run `platform_moderation.sql` again afterwards.
Otherwise ban enforcement silently switches off — the app would still show
the sanction, but the database would stop hiding anyone.

---

## 2. Edge Functions — nine to paste

Dashboard → **Edge Functions** → Deploy a new function → **Via Editor**. Name
each one **exactly** as listed. Paste-ready, self-contained copies (the
`_shared/` code is already inlined) live in `docs/edge_functions_paste/`.

### New — in-app payment setup won't work without this

| Function | Does |
|---|---|
| `payments-connect-fields` | Native onboarding: what Stripe still needs, and taking it from the app's own form |

This is the one that makes "Set up payments" stop being a web page. Accounts it
creates use `controller.requirement_collection: "application"`, which is what
lets a platform collect the details over the API — Express accounts (what the
old `payments-onboard` made) can only ever be onboarded on Stripe's own pages.

**What that costs:** with requirement collection on the application, the
platform also takes `losses.payments: "application"` — disputes and negative
balances land on the platform rather than on Stripe. That is the trade for
native onboarding, and it is a business decision. Existing Express accounts
cannot be converted; anyone who already has one is offered Stripe's page for
that account, and a fresh account is native.

No new secrets. Bank account numbers and SIN/SSN never reach it: the app
tokenises them against Stripe with the publishable key and sends only
`btok_…` / `piitok_…`, and the function refuses anything else.

### New — moderation won't work without these

| Function | Does |
|---|---|
| `moderation-status` | Tells a device its own role and sanction |
| `moderation-act` | Applies and lifts sanctions — every authority check lives here |
| `moderation-queue` | Reports, live sanctions, the audit log |

No new secrets needed; they only use `SUPABASE_URL` and
`SUPABASE_SERVICE_ROLE_KEY`, which are already set.

### Changed — the deployed copies are behind

| Function | What the update fixes |
|---|---|
| `payments-account-session` | The Connect onboarding "error occurred while authenticating" |
| `payments-webhook` | Writes the blue check into the directory so peers see it |
| `payments-create-intent` | Sender pays the fees (grossing up), send guards |
| `payments-history` | Transaction history (needs SQL #1) |
| `payments-settings` | Receive controls (needs SQL #1) |
| `identity-start` | Returns a client secret, so the ID check runs on the app's own themed screen instead of Stripe's generic hosted page |

`identity-start` is optional — the ID check stays inside the app either way
now. Re-pasting it is a cosmetic upgrade, not a fix.

---

## 3. Secrets — check one, the rest are optional

Dashboard → Edge Functions → **Secrets**.

### What is actually broken, as of the last round of testing

Payments **work in the web build** and fail in the app. That difference is not
the platform: the web build has no WebView, so it has always used Stripe's
*hosted* onboarding, while the app used the *embedded* component. So the
embedded path is the broken one, and only two things can break it — both
invisible from a phone:

1. the app's publishable key and the server's `STRIPE_SECRET_KEY` belonging to
   different Stripe accounts (only the embedded flow uses the publishable key);
2. WKWebView refusing the cross-site iframe the component runs in.

**Wallet → Check payments setup** settles which. It reports both keys' modes and
Stripe accounts and names the mismatch, or says the keys are fine — in which
case it is (2). The **Server key** line needs the updated
`payments-account-session` pasted; without it that half is unknown.

Meanwhile the app goes straight to the hosted flow, which is the one observed
working. It still runs inside the app's own WebView — no browser, no popup.
Switch back with `--dart-define=PREFER_EMBEDDED_CONNECT=true` once the cause is
known and fixed.

### ⚠️ `STRIPE_SECRET_KEY` must match the key the app is built with

This is the one to check if setting up payments says **"An error occurred while
authenticating your account."** That is Stripe's wording for *the publishable
key cannot authenticate this session*, and it points at your Stripe account
when the problem is the pair of keys. Two ways they fail to pair:

1. **Different modes.** The app is built with `pk_live_…`, so
   `STRIPE_SECRET_KEY` has to be an `sk_live_…` key. A test secret key mints a
   test session, which a live publishable key cannot authenticate.
2. **Different accounts.** Two live keys from two different Stripe accounts
   fail the same way.

The app's publishable key belongs to Stripe account
**`acct_1EXa8MFoLcXnRrCb`** (checked against Stripe, not assumed). So:

> Dashboard → Edge Functions → Secrets → `STRIPE_SECRET_KEY` must be an
> `sk_live_…` key from `acct_1EXa8MFoLcXnRrCb`.

Get it from Stripe → Developers → API keys, with **Test mode off**, while
signed into that account. Nothing else needs changing for this.

The setup screen now says which of the two it is: it asks Stripe which account
the app's own key belongs to, and prints that under the failure. Once
`payments-account-session` is re-pasted it also reports the account the *secret*
key belongs to, and the screen names the mismatch outright instead of asking
you to compare them.

| Secret | Needed for | Without it |
|---|---|---|
| `STRIPE_SECRET_KEY` | **All payments and the ID check** | Every payment function fails |
| `STRIPE_WEBHOOK_SECRET` | `payments-webhook` signature check | Webhook rejects Stripe's calls |
| `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID` | Push notifications | Push stays inert |
| `PLATFORM_FEE_PERCENT`, `PLATFORM_FEE_FIXED_CENTS` | Fee override | Defaults to 3.4% + 10¢ |
| `APP_RETURN_URL` | Where hosted flows return | Defaults to the GitHub Pages site |
| `CONNECT_COUNTRY` | Connect account country | Defaults in code |
| `STATEMENT_DESCRIPTOR` | Card statement text | Stripe default |

Never put a secret key in the repo or in chat — the dashboard is the only place
it belongs. (The `sb_publishable_…` and `pk_live_…` keys are different: those
are client-safe and already inlined in the build configs on purpose.)

---

## 4. Not SQL or functions, but still pending

- **Supabase → Authentication → URL Configuration**: set Site URL and add
  `https://kingimann.github.io/OkayMessaging/` to Redirect URLs, or email
  confirmation links land on `localhost`.
- **Supabase → Authentication → Email Templates → Magic Link**: include
  `{{ .Token }}` so signing in by email shows a code.
- **Stripe Dashboard**: enable the `amount_capturable_updated` and
  connected-account events on the webhook, and the Connect embedded
  components.
- **GitHub → Settings → Secrets → Actions**: add `MAPBOX_TOKEN` so the *web*
  build gets the Mapbox basemap (iOS already has it via Codemagic).
- **App Store Connect**: create the IAP products and enable the In-App
  Purchase capability — see `docs/in_app_purchases_setup.md`.
