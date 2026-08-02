-- Okay Messaging — minimal identity registry
-- =============================================
-- Run this ONCE in your Supabase project: Dashboard → SQL Editor → paste →
-- Run. It creates the ONLY server-side data the app keeps: the mapping from a
-- verified phone number to its chosen username, used to (a) check whether a
-- username is available and (b) tell which username is linked to a number.
--
-- No messages, calls, media, or chats are ever stored on the server. Those are
-- relayed live between devices (Supabase Realtime broadcast) and kept only in
-- each device's local storage, so they're gone when the app is deleted.

create table if not exists public.usernames (
  phone      text primary key,           -- E.164 digits, e.g. 15551234567
  username   text not null,
  name       text not null default '',   -- display name, for the people directory
  phone_hash text,                       -- sha256(E.164), for contact-sync matching
  updated_at timestamptz not null default now()
);

-- Migration for projects created before the directory columns existed. Safe to
-- run repeatedly; adds the columns only if they're missing.
alter table public.usernames add column if not exists name text not null default '';
alter table public.usernames add column if not exists phone_hash text;

-- Case-insensitive uniqueness: "Ada" and "ada" are the same username.
create unique index if not exists usernames_username_lower_idx
  on public.usernames (lower(username));

-- Fast lookup for "which of my contacts use the app" (contact sync sends
-- sha256 hashes of phone numbers, never the raw numbers).
create index if not exists usernames_phone_hash_idx
  on public.usernames (phone_hash);

alter table public.usernames enable row level security;

-- Only a phone that has verified via SMS OTP (an authenticated user) can read
-- the registry to check availability...
drop policy if exists usernames_read on public.usernames;
create policy usernames_read on public.usernames
  for select to authenticated using (true);

-- ...and a user may only claim / change the row for their OWN verified number.
-- Supabase puts the verified phone in the JWT as `phone` (E.164 digits).
drop policy if exists usernames_insert_own on public.usernames;
create policy usernames_insert_own on public.usernames
  for insert to authenticated
  with check (phone = (auth.jwt() ->> 'phone'));

drop policy if exists usernames_update_own on public.usernames;
create policy usernames_update_own on public.usernames
  for update to authenticated
  using (phone = (auth.jwt() ->> 'phone'))
  with check (phone = (auth.jwt() ->> 'phone'));

-- =============================================================================
-- Payments (Stripe Connect Express)
-- =============================================================================
-- These tables hold ONLY payment metadata needed for routing and status — never
-- card numbers (PCI stays with Stripe) and never user funds (money lives in each
-- receiver's Stripe connected-account balance and auto-pays out to their bank).
-- They are written exclusively by the Edge Functions using the service-role key;
-- RLS is on with no anon/authenticated policies, so the client can't read them
-- directly (it goes through the functions).

-- Maps a verified phone to its Stripe Express connected account + KYC status.
create table if not exists public.payment_accounts (
  phone             text primary key,      -- E.164 digits
  stripe_account_id text not null,
  charges_enabled   boolean not null default false,
  payouts_enabled   boolean not null default false,
  details_submitted boolean not null default false,
  updated_at        timestamptz not null default now()
);
alter table public.payment_accounts enable row level security;

-- One row per PaymentIntent: who paid whom, how much, the platform fee, status.
create table if not exists public.payment_transactions (
  id                text primary key,      -- Stripe PaymentIntent id
  from_phone        text not null,
  to_phone          text not null,
  amount_cents      integer not null,
  fee_cents         integer not null default 0,
  currency          text not null default 'cad',
  status            text not null default 'requires_payment',
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
alter table public.payment_transactions enable row level security;

-- Latest payout state per connected account (from payout.* webhooks), so a
-- receiver can see "paid out to bank" status in-app.
create table if not exists public.payout_status (
  stripe_account_id text primary key,
  status            text not null,
  amount_cents      integer,
  arrival_date      timestamptz,
  updated_at        timestamptz not null default now()
);
alter table public.payout_status enable row level security;

-- =============================================================================
-- Push notifications (APNs)
-- =============================================================================
-- One device token per verified phone. Written by the signed-in owner from
-- the app; read ONLY by the push-send Edge Function (service role).
create table if not exists public.push_tokens (
  phone      text primary key,           -- E.164 digits
  token      text not null,              -- APNs device token (hex)
  platform   text not null default 'ios',
  -- The device owner's "private notifications" choice, enforced by push-send:
  -- when true every alert to this device says "New message" and nothing else.
  -- Stored server-side because the push is composed on the SENDER's device —
  -- a preference protecting this lock screen cannot live in someone else's
  -- settings.
  private    boolean not null default false,
  updated_at timestamptz not null default now()
);
alter table public.push_tokens
  add column if not exists private boolean not null default false;

alter table public.push_tokens enable row level security;

drop policy if exists push_tokens_upsert_own on public.push_tokens;
create policy push_tokens_upsert_own on public.push_tokens
  for insert to authenticated
  with check (phone = (auth.jwt() ->> 'phone'));

drop policy if exists push_tokens_update_own on public.push_tokens;
create policy push_tokens_update_own on public.push_tokens
  for update to authenticated
  using (phone = (auth.jwt() ->> 'phone'))
  with check (phone = (auth.jwt() ->> 'phone'));

-- YOUR OWN ROW HAS TO BE VISIBLE TO YOU, and it is worth saying why because
-- the obvious reading is that it should not be.
--
-- The app upserts its token on every launch, which PostgREST issues as
-- `insert ... on conflict do update`. When the row already exists, Postgres
-- applies the UPDATE policy to it — and a row no SELECT policy makes visible
-- cannot be updated that way. With no read policy at all, the first launch
-- inserted fine and every launch after it failed:
--
--   42501  new row violates row-level security policy for table "push_tokens"
--
-- read from the project's Postgres logs, once per launch, silently — the app
-- swallows the error, so push simply never updated its token.
--
-- The policy is the row, and the row is only ever yours. `anon` is refused
-- outright; a signed-in client sees one row, its own.
--
-- The token column IS readable — to that client, of its own row, only. Hiding
-- it was tried and does not work: PostgREST writes the upsert as
-- `... do update set token = excluded.token`, and `excluded` is a pseudo-row
-- OF THE TARGET TABLE, so reading it needs SELECT on that column. Revoking it
-- turns the silent RLS failure into a silent privilege failure and fixes
-- nothing. It costs nothing either: a device reading back the APNs token it
-- just generated learns something it already had. What must not happen is
-- reading somebody else's, and that is the policy's job, not a column grant's.
drop policy if exists push_tokens_read_own on public.push_tokens;
create policy push_tokens_read_own on public.push_tokens
  for select to authenticated
  using (phone = (auth.jwt() ->> 'phone'));

revoke all on table public.push_tokens from anon;
-- Named rather than left to Supabase's default grant on new tables in public.
-- A table this file bothers to revoke from should not depend on an implicit
-- grant for the half it keeps.
grant select, insert, update on public.push_tokens to authenticated;

-- =============================================================================
-- Crash reports
-- =============================================================================
-- Dart-side crashes and errors, reported by the app so problems can be read
-- from the dashboard instead of reconstructed from user descriptions. Rows
-- carry an error, a trimmed stack, build stamp, platform — never message
-- content or phone numbers. The client rate-limits itself; size caps here
-- are the backstop.
create table if not exists public.crash_reports (
  id          bigint generated always as identity primary key,
  created_at  timestamptz not null default now(),
  error       text not null check (char_length(error) <= 2000),
  stack       text not null default '' check (char_length(stack) <= 8000),
  context     text not null default '',
  app_version text not null default '',
  platform    text not null default '',
  mode        text not null default ''
);

alter table public.crash_reports enable row level security;

-- Anyone with the app (publishable key) may file a report...
drop policy if exists crash_reports_insert on public.crash_reports;
create policy crash_reports_insert on public.crash_reports
  for insert to anon, authenticated with check (true);

-- ...and reports are readable with the same key, so whoever is debugging can
-- pull them without service-role access. Crash stacks contain no user data.
drop policy if exists crash_reports_read on public.crash_reports;
create policy crash_reports_read on public.crash_reports
  for select to anon, authenticated using (true);

-- =============================================================================
-- Offline mailbox
-- =============================================================================
-- Store-and-forward for messages sent while the recipient's app was closed:
-- the SAME end-to-end-encrypted envelope the realtime broadcast carries,
-- held as ciphertext until the recipient drains it. The server can never
-- read a message. Rows are deleted by the recipient on delivery and swept
-- after 14 days unclaimed — nothing accumulates.
create table if not exists public.mailbox (
  id         bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  inbox      text not null,
  payload    jsonb not null
);

create index if not exists mailbox_inbox_idx
  on public.mailbox (inbox, created_at);

alter table public.mailbox enable row level security;

-- The app's publishable key both queues envelopes for others and drains /
-- deletes its own inbox. Bodies are E2E ciphertext, so readability of rows
-- reveals nothing.
drop policy if exists mailbox_insert on public.mailbox;
create policy mailbox_insert on public.mailbox
  for insert to anon, authenticated with check (true);

drop policy if exists mailbox_select on public.mailbox;
create policy mailbox_select on public.mailbox
  for select to anon, authenticated using (true);

drop policy if exists mailbox_delete on public.mailbox;
create policy mailbox_delete on public.mailbox
  for delete to anon, authenticated using (true);
