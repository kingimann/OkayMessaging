-- Auto-renewable storage subscriptions.
-- ============================================================================
-- Run this ONCE in the Supabase dashboard (SQL Editor -> New query -> Run).
--
-- WHY IT EXISTS. Apple bills an auto-renewable subscription every month on its
-- own. Without somewhere to record what Apple says, the app can only know
-- about the first purchase: month two would charge the customer while their
-- storage quietly lapsed. This table is the entitlement of record, written by
-- `iap-validate` (first purchase / restore) and kept current by `iap-notify`
-- (App Store Server Notifications V2).
--
-- WHAT'S IN IT. Nothing Apple didn't already tell us, plus the phone that
-- links a subscription to an account — the same identifier `push_tokens` and
-- `payment_accounts` already use. No payment details ever land here; Apple
-- handles the money and never shares a card with us.

create table if not exists public.subscriptions (
  -- Stable for the life of a subscription, and the only identifier Apple's
  -- renewal notifications carry.
  original_transaction_id text primary key,
  phone       text        not null,          -- E.164 digits
  product_id  text        not null,
  gb          int         not null default 0,
  expires_at  timestamptz,
  -- active | canceled (won't renew, still paid up) | grace (billing retry)
  -- | expired | refunded
  status      text        not null default 'active',
  environment text        not null default 'Production',
  updated_at  timestamptz not null default now()
);

create index if not exists subscriptions_phone_idx
  on public.subscriptions (phone);

-- Locked down completely: only the Edge Functions touch this, and they use the
-- service-role key, which bypasses RLS. Enabling RLS with no policies means a
-- client holding the publishable key can neither read nor write it — which
-- matters, because this table is what says who has paid.
alter table public.subscriptions enable row level security;

-- Explicitly drop any policy an earlier run may have created.
drop policy if exists subscriptions_select on public.subscriptions;
drop policy if exists subscriptions_insert on public.subscriptions;
drop policy if exists subscriptions_update on public.subscriptions;

-- Sanity check: should return zero rows for the anon role.
-- select * from public.subscriptions;
