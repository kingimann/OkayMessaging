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
  updated_at timestamptz not null default now()
);

-- Case-insensitive uniqueness: "Ada" and "ada" are the same username.
create unique index if not exists usernames_username_lower_idx
  on public.usernames (lower(username));

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
