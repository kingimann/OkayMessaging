-- A number or email already in use cannot be claimed twice (2026-08-09).
-- Run AFTER docs/platform_moderation.sql and docs/banned_signups.sql.
--
-- Two doors were open:
--
--   * PHONE — signing UP with a number that already has an account, and
--     attaching a number to a name-only account when somebody else already
--     holds it. Both ended with two accounts pointing at one number. Signing
--     IN with your own existing number is of course fine and is untouched;
--     the difference is which button was pressed, and only signup/attach ask.
--
--   * EMAIL — nothing stopped the same address being attached to any number
--     of accounts, because there was no server-side record of who holds one.
--
-- EMAILS ARE NEVER STORED HERE. The client sends sha256 of the trimmed,
-- lowercased address and the server holds only that — the same shape as
-- `usernames.phone_hash` in schema.sql. So this can answer "is it taken?"
-- and "release mine" without the project ever holding a list of its users'
-- email addresses. (The `banned_emails` list is plaintext on purpose: it is
-- small, admin-curated, and has to be matched by a human typing it.)
--
-- Neither table is readable or writable by a client. Everything goes through
-- the definer functions below, so the claims list can never be enumerated —
-- a downloadable email-hash list is a rainbow-table offline in an afternoon.
-- ---------------------------------------------------------------------------

-- Which account holds which email. One row per address, keyed by its hash.
create table if not exists public.email_claims (
  email_hash text primary key,             -- sha256(lower(trim(email)))
  phone      text not null,                -- digits, the holder
  claimed_at timestamptz not null default now()
);

create index if not exists email_claims_phone_idx on public.email_claims (phone);

alter table public.email_claims enable row level security;
-- No policies and no grants: the definer functions are the only way in.
revoke all on table public.email_claims from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Is this number already an account?
--
-- Canonicalizes both sides, like is_phone_banned — the directory stores
-- E.164 and a client passes digits, the '+'-vs-digits trap the follow and
-- admin lookups already learned the hard way. Callable by anon, because the
-- question is asked at SIGNUP, before there is any session.
--
-- It answers only yes/no about a number the caller already typed, so it
-- reveals nothing they could not learn by trying to sign in.
create or replace function public.is_phone_taken(p text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists(
    select 1 from public.usernames u
     where regexp_replace(u.phone, '\D', '', 'g')
         = regexp_replace(coalesce(p, ''), '\D', '', 'g')
       and regexp_replace(coalesce(p, ''), '\D', '', 'g') <> ''
  );
$$;

grant execute on function public.is_phone_taken(text) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Is this email hash held by SOMEBODY ELSE?
--
-- Excludes the caller's own claim, so re-saving your own address is not
-- "taken". A signed-out caller has no phone, so every existing claim counts.
create or replace function public.is_email_taken(h text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists(
    select 1 from public.email_claims c
     where c.email_hash = coalesce(h, '')
       and coalesce(h, '') <> ''
       and c.phone is distinct from
           regexp_replace(coalesce(auth.jwt() ->> 'phone', ''), '\D', '', 'g')
  );
$$;

grant execute on function public.is_email_taken(text) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Claim an email hash for the CALLER. Refuses (false) when another account
-- holds it; moves the caller's previous claim aside so changing your address
-- frees the old one. Needs a session — the claim is meaningless without a
-- phone to attach it to.
create or replace function public.claim_email(h text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  me text := regexp_replace(coalesce(auth.jwt() ->> 'phone', ''), '\D', '', 'g');
begin
  if me = '' or coalesce(h, '') = '' then
    return false;
  end if;
  -- Held by somebody else: refuse rather than steal it.
  if exists(select 1 from public.email_claims c
             where c.email_hash = h and c.phone <> me) then
    return false;
  end if;
  -- One address per account: drop whatever this account held before.
  delete from public.email_claims where phone = me;
  insert into public.email_claims (email_hash, phone) values (h, me)
    on conflict (email_hash) do update set phone = me, claimed_at = now();
  return true;
end;
$$;

grant execute on function public.claim_email(text) to authenticated;

-- Release the caller's claim (removing the address from the account).
create or replace function public.release_email()
returns void
language sql
security definer
set search_path = public
as $$
  delete from public.email_claims
   where phone = regexp_replace(
           coalesce(auth.jwt() ->> 'phone', ''), '\D', '', 'g')
     and regexp_replace(coalesce(auth.jwt() ->> 'phone', ''), '\D', '', 'g') <> '';
$$;

grant execute on function public.release_email() to authenticated;
