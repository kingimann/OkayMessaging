-- Banning an account bans the EMAIL behind it (2026-08-16).
--
-- Run after docs/banned_signups.sql (the address list and the role gate) and
-- docs/taken_signups.sql (email_claims, which maps an email hash to the
-- account holding it).
--
-- WHY THIS EXISTS. Letting an email-verified account with no phone number use
-- the whole app (supabase/functions/email-account) makes ban evasion cheap:
-- a ban lands on the account's CODE, and a code costs nothing to re-mint, so
-- the same person signs up again with the same inbox and is straight back in.
-- A phone number was the thing that made evasion expensive; an email is not,
-- which is exactly why DisposableEmails exists on the client. This closes the
-- loop by making a ban stick to the address as well as to the account.
--
-- WHY A SECOND TABLE INSTEAD OF REUSING banned_emails. `banned_emails` is
-- keyed by the ADDRESS, in the clear — fine for a moderator typing one in.
-- But `email_claims` deliberately holds only `sha256(lower(trim(email)))`
-- (its own comment: "a downloadable email-hash list is a rainbow-table
-- offline in an afternoon" is the reason it is not readable, and the address
-- itself is never stored at all). So when a moderator bans an ACCOUNT, the
-- address is not recoverable from anything the server holds — only its hash
-- is. Adding it to `banned_emails` is therefore impossible, not merely
-- awkward. This table is the hash-keyed twin, and the two are checked
-- separately by whoever holds the form they can check.
--
-- WHY NO SERVER-SIDE HASHING. Nothing in this project hashes in Postgres —
-- there is no pgcrypto dependency anywhere, and `claim_email` already takes a
-- hash computed by the caller. That stays true here: `is_email_hash_banned`
-- takes a hash, and the one caller that holds a plaintext address (the
-- `email-account` function, which has the confirmed email on the session)
-- computes the digest itself. Adding an extension dependency to check a
-- string the caller can hash in three lines would buy nothing.

-- Which email hashes are barred. One row per hash.
create table if not exists public.banned_email_hashes (
  email_hash  text primary key,           -- sha256(lower(trim(email)))
  actor_phone text not null default '',   -- who banned it (digits)
  reason      text not null default '',
  created_at  timestamptz not null default now()
);
alter table public.banned_email_hashes enable row level security;
-- No policy and no grants: the definer functions below are the only doors,
-- the same posture as banned_emails and email_claims. A client that could
-- read this could confirm a guessed address offline.
revoke all on table public.banned_email_hashes from anon, authenticated;

-- Is this hash barred? A yes/no about a hash the caller already holds, so
-- it reveals nothing it did not bring with it — the same posture as
-- is_email_taken, which is granted the same way and for the same reason.
create or replace function public.is_email_hash_banned(h text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists(select 1 from public.banned_email_hashes
                 where email_hash = coalesce(h, ''));
$$;
revoke all on function public.is_email_hash_banned(text) from public;
-- Named explicitly: Supabase grants EXECUTE on every new function in `public`
-- to anon and authenticated by default, and revoking the PUBLIC pseudo-role
-- leaves those standing. That trap cost a real hole once already
-- (find_people_by_hashes) and the fix is to name the role.
revoke all on function public.is_email_hash_banned(text) from anon, authenticated;
grant execute on function public.is_email_hash_banned(text) to anon, authenticated;

-- Owner/admin only: bar the email behind account [p], addressed by the phone
-- or account code the ban itself names. Returns false and changes nothing for
-- anyone else, and for an account that never attached an email.
create or replace function public.ban_account_email(p text, reason text default '')
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare ph text; ok boolean; target text; h text;
begin
  ph := regexp_replace(coalesce(auth.jwt() ->> 'phone', ''), '\D', '', 'g');
  target := regexp_replace(coalesce(p, ''), '\D', '', 'g');
  if ph = '' or target = '' then return false; end if;
  select exists(
    select 1 from public.platform_roles r
     where regexp_replace(r.phone, '\D', '', 'g') = ph
       and r.role in ('owner', 'admin')) into ok;
  if not ok then return false; end if;
  -- Canonicalized on both sides: an account code is stored bare while a
  -- phone may carry a '+', and comparing them as written would miss.
  select c.email_hash into h
    from public.email_claims c
   where regexp_replace(c.phone, '\D', '', 'g') = target
   limit 1;
  if h is null or h = '' then return false; end if;
  insert into public.banned_email_hashes (email_hash, actor_phone, reason)
    values (h, ph, reason)
    on conflict (email_hash) do nothing;
  return true;
end;
$$;
revoke all on function public.ban_account_email(text, text) from public;
revoke all on function public.ban_account_email(text, text) from anon, authenticated;
grant execute on function public.ban_account_email(text, text) to authenticated;

-- Owner/admin only: lift it again. Same gate, same canonicalization.
create or replace function public.unban_account_email(p text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare ph text; ok boolean; target text; h text;
begin
  ph := regexp_replace(coalesce(auth.jwt() ->> 'phone', ''), '\D', '', 'g');
  target := regexp_replace(coalesce(p, ''), '\D', '', 'g');
  if ph = '' or target = '' then return false; end if;
  select exists(
    select 1 from public.platform_roles r
     where regexp_replace(r.phone, '\D', '', 'g') = ph
       and r.role in ('owner', 'admin')) into ok;
  if not ok then return false; end if;
  select c.email_hash into h
    from public.email_claims c
   where regexp_replace(c.phone, '\D', '', 'g') = target
   limit 1;
  if h is null or h = '' then return false; end if;
  delete from public.banned_email_hashes where email_hash = h;
  return true;
end;
$$;
revoke all on function public.unban_account_email(text) from public;
revoke all on function public.unban_account_email(text) from anon, authenticated;
grant execute on function public.unban_account_email(text) to authenticated;
