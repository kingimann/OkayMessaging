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
