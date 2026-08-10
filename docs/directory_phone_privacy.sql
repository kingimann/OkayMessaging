-- The directory stops handing out phone numbers in bulk.
-- ============================================================================
-- Run ONCE in the Supabase SQL editor, AFTER docs/directory_numberless.sql
-- (it replaces that file's find_people) and docs/directory_privacy.sql
-- (find_by_username / find_by_phone).
--
-- WHAT WAS WRONG. Two doors, and the second was the wide one:
--
--   1. find_people(q) is granted to ANON and returned `phone` as its first
--      column. A two-character prefix answered up to 25 rows, so roughly
--      1,300 queries with nothing but the publishable key — which ships in
--      the web build and is readable by anyone — walked most of the handle
--      space and collected real E.164 numbers on the way.
--   2. usernames_read was `for select to authenticated using (... or not
--      is_locked_out(phone))`. Any account that could sign up could then
--      select the WHOLE table, phone column included, unbounded. Fixing (1)
--      alone would have been theatre.
--
-- Everywhere else in this schema the pattern is already right — market_listings,
-- public_forum and server_directory all revoke the table-wide select and hand
-- back every column but the poster's phone. The directory was the exception,
-- and it is the one table where the phone IS every row's primary key.
--
-- WHAT THIS DOES.
--   * find_people(q) still answers anon (a numberless account has no session
--     and the handle is the only thing it can be found by) but returns a
--     phone ONLY when q is the EXACT handle. A prefix search — the thing that
--     scales — now returns names and handles and nothing to dial.
--   * usernames_read narrows to the caller's OWN row. Everything the app used
--     to read across other people's rows moves to a definer function below,
--     each one answering a single question rather than handing over the table.
--
-- WHAT THIS DOES NOT DO, stated rather than implied. Exact-handle resolution
-- is still unmetered: enumerate handles with find_people, then ask once per
-- handle, and the numbers come out one at a time. That is far slower and far
-- more attributable than 25-at-a-time, but it is a cost increase, not a wall.
-- A wall needs per-caller rate limiting, and a SECURITY DEFINER function
-- cannot see the caller's IP — that belongs in an Edge Function, and it is
-- the follow-up. Sign-in by username is why the anon door cannot simply be
-- shut: the caller is signed out by definition and needs the number to send
-- itself a code.

-- ---------------------------------------------------------------------------
-- 1. Search: handles and names for anyone, a number only for an exact match.
--
-- This is the THIRD definition of find_people: directory_numberless.sql
-- installs it, account_lifecycle.sql replaces it to add the `hidden` filter
-- (a deactivated account answers no search), and this one replaces that. Both
-- earlier filters have to be carried forward or running this file quietly
-- reactivates everybody who deactivated — which is exactly what check_sql.sh
-- caught the first time this was written. Whatever redefines it next: copy
-- every `and` below, not just the ones your own change is about.
drop function if exists public.find_people(text);

create function public.find_people(q text)
returns table (phone text, username text, name text, verified boolean)
language plpgsql security definer set search_path = public as $$
begin
  -- Handle-shaped queries only; anything else could smuggle LIKE wildcards.
  if q is null or q !~ '^[a-z0-9_.]{2,32}$' then
    return;
  end if;
  return query
    select
      -- The whole fix. A prefix match is a browsing result and gets no
      -- number; only somebody who typed the handle exactly — which is what
      -- signing in and opening a chat both do — is answered with one.
      case when lower(u.username) = q then u.phone else '' end,
      u.username,
      u.name,
      coalesce(u.verified, false)
    from public.usernames u
    -- '_' is a legal handle character but a LIKE wildcard; escape it so
    -- searching a_b does not match axb.
    where lower(u.username) like replace(q, '_', '\_') || '%'
      and coalesce(u.find_by_username, true)
      -- From account_lifecycle.sql: a deactivated row answers no search.
      and not coalesce(u.hidden, false)
      and not public.is_locked_out(u.phone)
    order by u.username
    limit 25;
end $$;

revoke all on function public.find_people(text) from public;
grant execute on function public.find_people(text) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. The table itself: your own row, and nobody else's.
drop policy if exists usernames_read on public.usernames;
create policy usernames_read on public.usernames
  for select to authenticated
  using (phone = (auth.jwt() ->> 'phone'));

-- ---------------------------------------------------------------------------
-- 3. The questions the app used to answer by reading other people's rows.
--    Each returns one fact rather than a row, and none of them returns a
--    phone the caller did not already supply.

-- Is this handle free? Answers 'available' | 'mine' | 'taken' — never who
-- holds it. Anon may ask: a handle is chosen during sign-up, before a session.
create or replace function public.username_status(uname text)
returns text
language plpgsql stable security definer set search_path = public as $$
declare
  me text := coalesce(auth.jwt() ->> 'phone', '');
  owner text;
begin
  if uname is null or uname !~ '^[a-z0-9_.]{2,32}$' then
    return 'invalid';
  end if;
  select u.phone into owner from public.usernames u
   where lower(u.username) = lower(uname) limit 1;
  if owner is null then return 'available'; end if;
  if me <> '' and owner = me then return 'mine'; end if;
  return 'taken';
end $$;

revoke all on function public.username_status(text) from public;
grant execute on function public.username_status(text) to anon, authenticated;

-- Contact sync. The caller hashed numbers out of its own address book, so it
-- already holds every number this can return — the hash IS the proof of that,
-- which is why this one may answer with phones. Capped so the array cannot be
-- turned into a brute-force oracle in one call.
create or replace function public.find_people_by_hashes(hashes text[])
returns table (phone text, username text, name text, verified boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  if hashes is null or array_length(hashes, 1) is null
     or array_length(hashes, 1) > 500 then
    return;
  end if;
  return query
    select u.phone, u.username, u.name, coalesce(u.verified, false)
    from public.usernames u
    where u.phone_hash = any(hashes)
      and coalesce(u.find_by_phone, true)
      and not public.is_locked_out(u.phone)
    limit 500;
end $$;

revoke all on function public.find_people_by_hashes(text[]) from public;
grant execute on function public.find_people_by_hashes(text[]) to authenticated;

-- Does this number have an account? The caller supplied the number, so a
-- yes/no adds nothing it could not learn by trying to message them.
create or replace function public.is_on_app(p text)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists(
    select 1 from public.usernames u
     where u.phone = coalesce(p, '') and coalesce(p, '') <> ''
  );
$$;

revoke all on function public.is_on_app(text) from public;
grant execute on function public.is_on_app(text) to anon, authenticated;

-- The handle on a number the caller already has. Used at sign-in, before
-- there is a session to read your own row with.
create or replace function public.username_for_phone(p text)
returns text
language sql stable security definer set search_path = public as $$
  select u.username from public.usernames u
   where u.phone = coalesce(p, '') and coalesce(p, '') <> ''
   limit 1;
$$;

revoke all on function public.username_for_phone(text) from public;
grant execute on function public.username_for_phone(text) to anon, authenticated;
