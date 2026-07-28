# Server-side storage accounting (optional)

This is the "track usage yourself" half of the paid chat-backup plan. The app
already enforces the per-tier ceiling **on the device** (a backup that would
exceed your plan is refused before upload, and the Cloud storage screen warns
near the limit). This doc is about the **server** side: metering real usage,
enforcing a fair-use egress limit, and watching the whole project against your
Supabase plan.

It is optional. Nothing here is required for the app to work; deploy it when
you want server-visible numbers and egress throttling.

## What it gives you

- **`user_storage_usage`** — one row per account: `used_bytes`, `tier`,
  `egress_bytes`, `period_start`. `used_bytes` is maintained automatically by a
  trigger, so it always equals the real sum of that account's stored blobs — it
  can't drift.
- **`record_egress(account, bytes)`** — call it wherever you serve a
  restore/download; it rolls over monthly.
- **`egress_over_limit(account)`** — true once an account's monthly downloads
  pass ~3× what it stores (the fair-use rule in the Terms). Use it to throttle.
- **`storage_totals`** view — accounts, free accounts, total bytes, total
  egress this month. Watch `total_used_bytes` against your plan (a $25 Pro
  project includes 100 GB / 250 GB egress); at ~80 GB, raise prices or archive
  cold blobs to R2/S3.

## Deploy

1. Run `docs/supabase_setup.sql` first (creates `sync_blobs`).
2. Run `docs/storage_usage_setup.sql`. It's idempotent — safe to re-run.

## Activating the client tag (one small change, on request)

Metering only counts blobs that carry an `account` tag. The migration adds that
column as **nullable**, so nothing breaks before the client sends it. To turn
metering on, the app needs to include a stable `account` value on each
`sync_blobs` upload — an HMAC of the phone number under a fixed app label (not
the encryption key, so it survives a passphrase change and still reveals
nothing about the number). Say the word once you've run the SQL and I'll wire
`CloudSync` to send it; until then the tables sit inert and correct.

## Honest limits

- **No server auth yet.** `REQUIRE_OTP` is off, so RLS can't bind a usage row
  to a verified caller — anyone with the publishable key could, in principle,
  write any account's row. The stored-bytes number is trustworthy (the trigger
  derives it from the actual blobs), but the egress ceiling is **advisory**:
  `egress_over_limit()` is a signal for your gateway/Edge Function to throttle,
  not a hard gate. A hard gate needs the SMS-OTP auth path turned on.
- **The 50-free-users / 100 GB cap is a business decision, enforced by you.**
  `storage_totals` gives you the number to watch; capping new free signups (or
  expiring/watermarking free backups, per your model) is a policy call to make
  when you get there.
- **Privacy trade.** Grouping blobs by an account tag lets the server see how
  many bytes/blobs one account holds. Blob *contents* stay end-to-end-encrypted
  ciphertext the server can't read. This is the minimal linkage needed to meter
  a paid plan.
