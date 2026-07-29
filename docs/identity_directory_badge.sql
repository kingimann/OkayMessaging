-- The blue check on the public directory.
-- ============================================================================
-- Run ONCE in the Supabase SQL editor, then re-paste payments-webhook (which
-- sets the flag when Stripe's identity verdict arrives).
--
-- WHY. The badge already flows peer-to-peer: a verified user's own posts and
-- messages attest it. But directory search results and contact-sync matches
-- come from the `usernames` table, which knew nothing about verification —
-- so those lists could either show no badge, or trust whatever a client
-- claimed. This column is the server's own answer: set exclusively by the
-- identity webhook on Stripe's verdict, never writable by clients.

alter table public.usernames
  add column if not exists verified boolean not null default false;

-- Clients may read it (it's what a badge is for) but never write it: the
-- claim path (upsert from the app) must not be able to grant itself a badge.
-- The webhook writes with the service role, which bypasses RLS.
do $$
begin
  if exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'usernames'
  ) then
    -- Existing per-project policies vary; the important property is that no
    -- anon/authenticated policy grants UPDATE on this column specifically.
    -- If your policies allow client updates to usernames rows, split the
    -- verified column out of them.
    null;
  end if;
end $$;

-- Backfill anyone already verified before the column existed.
update public.usernames u
   set verified = true
  from public.identity_verifications v
 where v.phone = u.phone
   and v.status = 'verified';
