-- Keeping a banned user's NUMBER and EMAIL from coming back.
-- ============================================================================
-- Run ONCE in the Supabase SQL editor, AFTER docs/platform_moderation.sql
-- (this leans on account_sanctions and platform_roles).
--
-- Two identifiers, two mechanisms:
--
--   * PHONE — a ban already lives in account_sanctions (kind 'ban'/'suspend').
--     is_phone_banned() is the canonicalizing lookup the signup path calls, so
--     a banned number is refused at the door instead of only being locked out
--     after it signs in. It canonicalizes both sides (the directory stores
--     E.164, a client passes digits) — the same '+' vs digits trap the follow
--     and admin lookups already learned.
--
--   * EMAIL — there is NO server column that maps an email to an account (a
--     verified email lives only inside the user's ENCRYPTED backup blob), so a
--     phone-ban cannot capture the email automatically. Instead an owner/admin
--     bans an email explicitly with ban_email(); the signup / email-set path
--     refuses anything on the list. The list is reachable only through the
--     definer functions — never enumerable by a client.

create table if not exists public.banned_emails (
  email       text primary key,          -- lowercased, trimmed
  actor_phone text not null default '',  -- who banned it (digits)
  reason      text not null default '',
  created_at  timestamptz not null default now()
);
alter table public.banned_emails enable row level security;
-- No client policy and no grants: the only doors are the definer functions
-- below. A raw list of banned emails is not something a client should read.
revoke all on table public.banned_emails from anon, authenticated;

-- Is this phone under an active ban or suspension? (A timeout is not a signup
-- ban — it lifts by itself.)
create or replace function public.is_phone_banned(p text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists(
    select 1 from public.account_sanctions s
     where regexp_replace(s.phone, '\D', '', 'g')
             = regexp_replace(p, '\D', '', 'g')
       and s.kind in ('ban', 'suspend')
       and (s.until is null or s.until > now()));
$$;
grant execute on function public.is_phone_banned(text) to anon, authenticated;

-- Is this email on the banned list?
create or replace function public.is_email_banned(e text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists(select 1 from public.banned_emails
                 where email = lower(trim(e)));
$$;
grant execute on function public.is_email_banned(text) to anon, authenticated;

-- Owner/admin only: add an email to the banned list. The caller is proven by
-- the JWT phone in platform_roles (canonicalized), the same gate the admin
-- roster uses. Returns false (changes nothing) for anyone else.
create or replace function public.ban_email(e text, reason text default '')
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare ph text; ok boolean;
begin
  ph := regexp_replace(coalesce(auth.jwt() ->> 'phone', ''), '\D', '', 'g');
  if ph = '' or lower(trim(e)) = '' then return false; end if;
  select exists(
    select 1 from public.platform_roles r
     where regexp_replace(r.phone, '\D', '', 'g') = ph
       and r.role in ('owner', 'admin')) into ok;
  if not ok then return false; end if;
  insert into public.banned_emails (email, actor_phone, reason)
    values (lower(trim(e)), ph, reason)
    on conflict (email) do nothing;
  return true;
end $$;
grant execute on function public.ban_email(text, text) to authenticated;

-- Owner/admin only: lift an email ban.
create or replace function public.unban_email(e text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare ph text; ok boolean;
begin
  ph := regexp_replace(coalesce(auth.jwt() ->> 'phone', ''), '\D', '', 'g');
  select exists(
    select 1 from public.platform_roles r
     where regexp_replace(r.phone, '\D', '', 'g') = ph
       and r.role in ('owner', 'admin')) into ok;
  if not ok then return false; end if;
  delete from public.banned_emails where email = lower(trim(e));
  return true;
end $$;
grant execute on function public.unban_email(text) to authenticated;
