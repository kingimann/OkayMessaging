-- Accounts banned from sending money, and the disputes that banned them.
-- ============================================================================
-- Run this ONCE in the Supabase dashboard (SQL Editor -> New query -> Run).
--
-- POLICY. A chargeback on a peer-to-peer transfer is not a billing disagreement
-- with a merchant — the money reached another person, who has already been
-- paid. Taking it back through the card network makes the recipient carry the
-- loss. So filing one ends the sender's ability to send.
--
-- WHY IT ALSO PROTECTS THE PLATFORM. Stripe closes accounts whose dispute
-- ratio climbs too high. Every dispute counts against that ratio whether it is
-- won or lost, so the cheapest dispute is the one that never happens and the
-- second cheapest is the one that never happens again.
--
-- WHAT IS STORED. A phone, a reason, the dispute and charge ids, and a
-- timestamp. No card details ever reach this project.

create table if not exists public.payment_bans (
  phone        text primary key,          -- E.164 digits of the sender
  reason       text not null default 'chargeback',
  dispute_id   text,
  charge_id    text,
  amount_cents int,
  banned_at    timestamptz not null default now()
);

create index if not exists payment_bans_banned_at_idx
  on public.payment_bans (banned_at);

-- Only the Edge Functions touch this, via the service-role key, which
-- bypasses RLS. Enabling RLS with no policies means a client holding the
-- publishable key can neither read it nor — far more importantly — delete
-- its own ban.
alter table public.payment_bans enable row level security;

drop policy if exists payment_bans_select on public.payment_bans;
drop policy if exists payment_bans_insert on public.payment_bans;
drop policy if exists payment_bans_delete on public.payment_bans;

-- Lifting a ban is a deliberate act, done here:
--   delete from public.payment_bans where phone = '15551234567';
