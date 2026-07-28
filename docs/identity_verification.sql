-- Government-ID verification behind the blue check.
-- ============================================================================
-- Run this ONCE in the Supabase dashboard (SQL Editor -> New query -> Run).
--
-- WHY IT EXISTS. The badge used to be a free toggle — tap "Verify me" and you
-- were verified — which made it a decoration rather than a claim about who
-- someone is. It now requires a Stripe Identity document check with a selfie
-- match, and this table is the record of who passed.
--
-- WHAT IS *NOT* IN IT. No document images, no name, no date of birth, no
-- document number. Stripe holds all of that; this table stores a phone, the
-- session id, and a status string. The app never sees the document either —
-- the check happens in Stripe's hosted flow.

create table if not exists public.identity_verifications (
  phone      text primary key,          -- E.164 digits
  session_id text not null,
  -- Stripe's own vocabulary: requires_input | processing | verified | canceled
  status     text not null default 'processing',
  updated_at timestamptz not null default now()
);

-- Locked down completely: only the Edge Functions touch this, via the
-- service-role key, which bypasses RLS. Enabling RLS with no policies means a
-- client holding the publishable key can neither read nor write it — which is
-- the entire point, since this table is what says whose identity was checked.
alter table public.identity_verifications enable row level security;

drop policy if exists identity_select on public.identity_verifications;
drop policy if exists identity_insert on public.identity_verifications;
drop policy if exists identity_update on public.identity_verifications;

-- Sanity check: should return zero rows for the anon role.
-- select * from public.identity_verifications;
