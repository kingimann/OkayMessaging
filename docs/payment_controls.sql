-- Who may send you money, how much can leave at once, and how much in a day.
-- ============================================================================
-- Run this in the Supabase dashboard (SQL Editor -> New query -> Run). Safe to
-- run again: a project already holding the first version is upgraded in place.
--
-- Every one of these is enforced in payments-create-intent, before a charge
-- exists. A limit the app applies is a limit a modified app ignores.

create table if not exists public.payment_settings (
  phone text primary key,                    -- E.164 digits

  -- Who is allowed to send money to this person.
  --   anyone  - the default
  --   nobody  - receiving is switched off entirely
  accepts_from text not null default 'anyone'
    check (accepts_from in ('anyone', 'nobody')),

  -- The most this account may SEND in a rolling 24 hours, in cents. Caps the
  -- damage from a phone someone else has picked up, and from a mistake made
  -- repeatedly. Null means the project default applies.
  daily_send_limit_cents int,

  -- The most one single transfer may be, in cents. A day's worth of small
  -- mistakes and one big one are different failures; the rolling cap only
  -- catches the first. Null or 0 means no per-transfer cap.
  max_send_cents int,

  -- Everything off, both directions, in one tap. Nothing leaves and nothing
  -- arrives while this is set.
  paused boolean not null default false,

  -- A raise that has been asked for and has not arrived yet. Lowering a limit
  -- takes effect immediately; raising one waits 24 hours, so an unlocked phone
  -- in the wrong hands is held to whatever its owner chose while calm. Both
  -- columns of a pair are set together or not at all.
  pending_daily_send_limit_cents int,
  pending_daily_effective_at timestamptz,
  pending_max_send_cents int,
  pending_max_effective_at timestamptz,

  updated_at timestamptz not null default now()
);

-- Added after the first version shipped. The columns are in the CREATE above
-- too, so a fresh project reads the whole table in one place; these ALTERs are
-- what upgrade a project that already ran v1. Both are no-ops on the other.
alter table public.payment_settings
  add column if not exists paused boolean not null default false;
alter table public.payment_settings
  add column if not exists max_send_cents int;
alter table public.payment_settings
  add column if not exists pending_daily_send_limit_cents int;
alter table public.payment_settings
  add column if not exists pending_daily_effective_at timestamptz;
alter table public.payment_settings
  add column if not exists pending_max_send_cents int;
alter table public.payment_settings
  add column if not exists pending_max_effective_at timestamptz;

-- People this account refuses money from, whatever accepts_from says.
create table if not exists public.payment_blocks (
  phone         text not null,   -- the recipient doing the blocking
  blocked_phone text not null,   -- the sender being refused
  created_at    timestamptz not null default now(),
  primary key (phone, blocked_phone)
);

-- Only the Edge Functions touch either table, via the service-role key, which
-- bypasses RLS. Enabling RLS with no policies means a client holding the
-- publishable key cannot raise its own send limit or unblock itself.
alter table public.payment_settings enable row level security;
alter table public.payment_blocks enable row level security;

drop policy if exists payment_settings_all on public.payment_settings;
drop policy if exists payment_blocks_all on public.payment_blocks;

-- The rolling-window sum the send limit is checked against. Only completed
-- and in-flight charges count; blocked and failed ones never took money.
create index if not exists payment_transactions_from_created_idx
  on public.payment_transactions (from_phone, updated_at);

-- What a transfer said it was for, so the history can show it (and mark
-- sparks). The note was always plaintext payment data — it already rides the
-- Stripe intent's metadata — so storing it here exposes nothing new. The
-- table stays RLS-locked; payments-history is still the only way to read it.
alter table public.payment_transactions
  add column if not exists note text not null default '';

-- ---------------------------------------------------------------------------
-- Debit-card attach history — the record behind two safeguards: a newly
-- attached card waits seven business days before instant payouts (an account
-- takeover attaches its own card and drains the balance in one motion; the
-- wait gives the real owner time to notice), and a third card inside thirty
-- days locks the feature until the changes age out. SERVICE ROLE ONLY: the
-- Edge Functions write and read it, clients get nothing — a row a client
-- could delete is a waiting period a thief could skip.
-- ---------------------------------------------------------------------------
create table if not exists public.payment_card_events (
  id         bigint generated always as identity primary key,
  phone      text not null,
  created_at timestamptz not null default now()
);
-- Bank (direct deposit) changes share the ledger: same safeguards, same
-- reasons — swapping where the money lands is the other half of the drain.
alter table public.payment_card_events
  add column if not exists kind text not null default 'card';
create index if not exists payment_card_events_phone_idx
  on public.payment_card_events (phone, created_at desc);
alter table public.payment_card_events enable row level security;
revoke all on table public.payment_card_events from anon, authenticated;
