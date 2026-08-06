-- Paid servers (2026-08-06). The membership half of creator subscriptions:
-- who has paid to be in a paid server, verified from a store receipt.
--
-- A paid server's traffic is already END-TO-END SEALED under its own secret,
-- so this is NOT access-control over readable content — the server never sees
-- or stores a message. It records who holds an active membership pass, so the
-- join can be gated and (the hardening follow-up) the owner's device can
-- release the secret only to a verified-paid joiner.
--
-- `community_passes` is written ONLY by the `community-subscribe` Edge Function
-- (service role), after it verifies the Apple receipt. There are NO client
-- grants on the tables at all; the definer functions below are the only doors,
-- and none of them ever returns a phone number.
--
-- Run this in the Supabase SQL editor, then paste the `community-subscribe`
-- function. Until then paid servers run in test/simulation only (the client's
-- local pass drives the demo).
-- ---------------------------------------------------------------------------

-- Both ends stay off the client. subscriber_phone is the payer; server_id is
-- the community id. last_txn_id dedupes a receipt so one purchase grants one
-- month. Keyed by (subscriber, server): one live pass per server per account.
create table if not exists public.community_passes (
  subscriber_phone text not null,
  server_id        text not null,
  expires_at       timestamptz not null,
  product_id       text not null default '',
  last_txn_id      text not null default '',
  updated_at       timestamptz not null default now(),
  primary key (subscriber_phone, server_id)
);

alter table public.community_passes enable row level security;
revoke all on table public.community_passes from anon, authenticated;

-- One row per consumed receipt, so the same signed transaction can't be
-- replayed to buy membership of a dozen servers.
create table if not exists public.community_sub_receipts (
  txn_id     text primary key,
  created_at timestamptz not null default now()
);
alter table public.community_sub_receipts enable row level security;
revoke all on table public.community_sub_receipts from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Read gates (security definer — the only doors). A client can ask about its
-- OWN passes; it can never grant itself one or read anybody else's.
-- ---------------------------------------------------------------------------

-- Whether the caller holds an active membership pass to [s] (a server id).
create or replace function public.community_pass_active(s text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
      from public.community_passes p
     where p.subscriber_phone = (auth.jwt() ->> 'phone')
       and p.server_id = s
       and p.expires_at > now()
  );
$$;

-- The caller's own active passes — server id + expiry — for reconciling the
-- local list on start. Only ever your own rows; no phone ever returned.
create or replace function public.community_my_passes()
returns table(server_id text, expires_at timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  select p.server_id, p.expires_at
    from public.community_passes p
   where p.subscriber_phone = (auth.jwt() ->> 'phone')
     and p.expires_at > now();
$$;

grant execute on function public.community_pass_active(text) to authenticated;
grant execute on function public.community_my_passes() to authenticated;
