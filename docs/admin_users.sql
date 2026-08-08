-- Admin user roster (2026-08-07)
-- ---------------------------------------------------------------------------
-- An owner/admin-only window onto the WHOLE account directory — including the
-- name-only ("numberless") signups whose key is a 00-prefixed account code, not
-- a phone. Those accounts get a real public.usernames row at sign-up
-- (claim_numberless), but they never appear in reports or sanctions, so before
-- this there was no way for staff to see them, or to know how many accounts
-- exist at all.
--
-- platform_roles is service-role only (RLS on, no client policy), so the staff
-- check runs INSIDE these security-definer functions: a client that isn't an
-- owner or admin — as the SERVER sees it, not as the app claims — gets nothing.
-- Neither function returns a phone number: staff act on an account by its
-- @username (the moderation console's "Act on account" already does), so the
-- roster is handles, names and flags, never the directory's phone column.
--
-- Run this AFTER platform_moderation.sql (platform_roles), directory_numberless.sql
-- (verified/find_by_username) and account_lifecycle.sql (hidden).

-- ---------------------------------------------------------------------------
-- Last seen (2026-08-08). A single timestamp per account, bumped by the client
-- on sign-in and every time the app comes to the foreground. It is what lets
-- the moderation roster show who is online now and when everyone else was last
-- around. Only the account itself can bump its own row (the definer function
-- resolves the caller from their JWT), and only staff can read it (through
-- admin_list_users). A NAME-ONLY account has no session, so it can never call
-- touch_last_seen — its last_seen stays null and the roster shows "never seen",
-- which is the honest answer: the app has no way to know it is online.
alter table public.usernames
  add column if not exists last_seen timestamptz;

-- The caller stamps their own last_seen = now(). Resolve the caller to their
-- directory phone by DIGITS (the JWT's phone claim has no '+', the directory
-- stores E.164 with one), the same normalisation public_follow uses.
create or replace function public.touch_last_seen()
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  jwt_phone text := nullif(auth.jwt() ->> 'phone', '');
begin
  if jwt_phone is null then return; end if;
  update public.usernames
     set last_seen = now()
   where regexp_replace(phone, '\D', '', 'g')
       = regexp_replace(jwt_phone, '\D', '', 'g');
end;
$$;

revoke execute on function public.touch_last_seen() from anon;
grant execute on function public.touch_last_seen() to authenticated;

-- How many accounts exist, all kinds. Owner/admin only.
create or replace function public.admin_user_count()
returns bigint
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  ph text := nullif(auth.jwt() ->> 'phone', '');
begin
  if ph is null or not exists (
      select 1 from public.platform_roles r
       where r.phone = ph and r.role in ('owner', 'admin')) then
    raise exception 'not authorised';
  end if;
  return (select count(*) from public.usernames);
end;
$$;

revoke execute on function public.admin_user_count() from anon;
grant execute on function public.admin_user_count() to authenticated;

-- The roster, newest first. numberless is true for a name-only account (its key
-- is a 00-prefixed code, not a phone). No phone column crosses the wire.
create or replace function public.admin_list_users(lim int default 200, off int default 0)
returns table(
  username    text,
  name        text,
  verified    boolean,
  hidden      boolean,
  numberless  boolean,
  updated_at  timestamptz,
  last_seen   timestamptz)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  ph text := nullif(auth.jwt() ->> 'phone', '');
begin
  if ph is null or not exists (
      select 1 from public.platform_roles r
       where r.phone = ph and r.role in ('owner', 'admin')) then
    raise exception 'not authorised';
  end if;
  return query
    select u.username,
           coalesce(u.name, ''),
           coalesce(u.verified, false),
           coalesce(u.hidden, false),
           (u.phone ~ '^00[0-9]{10}$'),
           u.updated_at,
           u.last_seen
      from public.usernames u
     -- Most-recently-active first: who's online floats to the top, then the
     -- freshest sign-ups (a name-only account has no last_seen, so it sorts
     -- by when its row was written).
     order by coalesce(u.last_seen, u.updated_at) desc
     limit greatest(1, least(lim, 500))
    offset greatest(0, off);
end;
$$;

revoke execute on function public.admin_list_users(int, int) from anon;
grant execute on function public.admin_list_users(int, int) to authenticated;
