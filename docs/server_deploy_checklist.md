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

No new secrets. Bank account numbers, SIN/SSN **and the photo of your ID**
never reach it: the app sends all three to Stripe from the device with the
publishable key — Stripe's file endpoint accepts that key over Bearer auth,
checked against the live API — and passes on only `btok_…`, `piitok_…` and
`file_…`. The function refuses anything that isn't one of those rather than
forwarding it.

So the whole of onboarding is the app's own screen: name, date of birth,
address, SIN, bank details and photo ID, each asked for only when Stripe says
it is due.

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

### The embedded-component failure: settled, and no longer relevant

For a long time setting up payments failed with Stripe's "an error occurred
while authenticating your account". Two things can cause that, and both were
chased here: the two Stripe keys being in different modes or belonging to
different accounts, or WKWebView refusing the cross-site iframe the embedded
component runs in.

**It was the WebView.** The keys are in the same mode and from the same Stripe
account — confirmed by the account's owner, who has no other Stripe account. So
there is nothing to fix about the keys, and nothing to go and check.

It stopped mattering anyway: onboarding no longer uses the embedded component,
or any web page. It is the app's own form, submitting over the API
(`payments-connect-fields`). Neither the publishable key nor an Account Session
is involved, so neither can break it.

Two things that follow, so nobody does pointless work:

* **Re-pasting `payments-account-session` is optional.** Its only remaining job
  is reporting the server key's Stripe account to the self-test. Nothing in the
  app depends on it.
* `--dart-define=PREFER_EMBEDDED_CONNECT=true` still exists, but there is no
  reason to use it. The embedded component is the path that did not work.

### `STRIPE_SECRET_KEY` and the app's key have to be a pair

Already true here — same account, same mode — so this is written down for
whoever sets the project up next rather than as something outstanding.

Two ways a pair can fail:

1. **Different modes.** The app is built with `pk_live_…`, so
   `STRIPE_SECRET_KEY` has to be an `sk_live_…` key. A test secret key mints a
   test session, which a live publishable key cannot authenticate.
2. **Different accounts.** Two live keys from two different Stripe accounts
   fail the same way.

The app's publishable key belongs to Stripe account
**`acct_1EXa8MFoLcXnRrCb`** — checked against Stripe, not assumed — and
`STRIPE_SECRET_KEY` is a live key from that same account. Both halves match.

**Wallet → Check payments setup** re-checks this on demand, and also reports the
thing that now decides whether setup is a form or a web page: whether the
connected account is one this app may collect for.

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

## 3b. ⚠️ GitHub Pages is deploying twice, and they overwrite each other

The site alternates between the Flutter app and the repository README. Proven,
not guessed: `main.dart.js` answered 404 with the README's Jekyll tags served at
the root, and answered 200 with the app a few minutes later once
`deploy-web.yml` finished.

The cause is the Pages **source** setting. With "Deploy from a branch", GitHub
runs its own implicit Jekyll build of the repo root — which renders README.md —
*and* `deploy-web.yml` publishes the Flutter build. Whichever finishes last is
what the site serves, so every push flips it.

**Fix (one setting, yours to change):** repository **Settings → Pages → Build
and deployment → Source**: change *Deploy from a branch* to **GitHub Actions**.
The implicit Jekyll build then stops running and only the Flutter build
publishes.

Until that is changed, the app and `connect.html` will keep disappearing for
minutes at a time after each push, with no error anywhere to explain it.

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
