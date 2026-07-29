-- Who may send you money, and how much can leave in a day.
-- ============================================================================
-- Run this ONCE in the Supabase dashboard (SQL Editor -> New query -> Run).
--
-- Both of these are enforced in payments-create-intent, before a charge
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

  updated_at timestamptz not null default now()
);

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
