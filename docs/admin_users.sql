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
  updated_at  timestamptz)
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
           u.updated_at
      from public.usernames u
     order by u.updated_at desc
     limit greatest(1, least(lim, 500))
    offset greatest(0, off);
end;
$$;

revoke execute on function public.admin_list_users(int, int) from anon;
grant execute on function public.admin_list_users(int, int) to authenticated;
