-- Username search and directory rows for accounts with no phone number.
-- ============================================================================
-- Run ONCE in the Supabase SQL editor, AFTER docs/platform_moderation.sql
-- (the search filter reuses its is_locked_out()).
--
-- WHY. A numberless account has no Supabase session at all — Supabase
-- authenticates a phone — and the directory's RLS speaks only to
-- `authenticated`. So such an account could neither claim its @handle nor
-- search anyone else's, and the handle is the ONE thing a numberless account
-- can be found by. Two SECURITY DEFINER functions open exactly that path and
-- nothing more:
--
--   find_people(q)      what an authenticated directory search already shows
--                       (opted-in, not-locked-out rows), now answerable with
--                       the anon key. The raw table stays unreadable to anon.
--   claim_numberless()  inserts a directory row for an ACCOUNT CODE only —
--                       12 digits with a leading 00, a shape no real E.164
--                       number can have — so a phone account's row still
--                       requires the verified session that owns it. First
--                       claim wins: with no session there is no way to prove
--                       a code is yours, so an existing row's handle can
--                       never be changed through here (only its display name,
--                       and only when the handle matches).

-- The columns the functions read, for projects that have not run
-- docs/directory_privacy.sql / docs/identity_directory_badge.sql yet.
alter table public.usernames
  add column if not exists find_by_username boolean not null default true;
alter table public.usernames
  add column if not exists verified boolean not null default false;

create or replace function public.find_people(q text)
returns table (phone text, username text, name text, verified boolean)
language plpgsql security definer set search_path = public as $$
begin
  -- Handle-shaped queries only; anything else could smuggle LIKE wildcards.
  if q is null or q !~ '^[a-z0-9_.]{2,32}$' then
    return;
  end if;
  return query
    select u.phone, u.username, u.name, coalesce(u.verified, false)
    from public.usernames u
    -- '_' is a legal handle character but a LIKE wildcard; escape it so
    -- searching a_b does not match axb.
    where lower(u.username) like replace(q, '_', '\_') || '%'
      and coalesce(u.find_by_username, true)
      and not public.is_locked_out(u.phone)
    order by u.username
    limit 25;
end $$;

revoke all on function public.find_people(text) from public;
grant execute on function public.find_people(text) to anon, authenticated;

create or replace function public.claim_numberless(
    code text, uname text, display text default '')
returns boolean
language plpgsql security definer set search_path = public as $$
begin
  -- Codes only. A real number's row is written through RLS by its session.
  if code is null or code !~ '^00[0-9]{10}$' then
    return false;
  end if;
  if uname is null or uname !~ '^[a-z0-9_.]{3,32}$' then
    return false;
  end if;
  if public.is_locked_out(code) then
    return false;
  end if;
  insert into public.usernames (phone, username, name, updated_at)
  values (code, uname, coalesce(display, ''), now())
  -- The same account re-claiming (a display-name change, a retried sign-up)
  -- is fine; CHANGING the handle is not — no session, no proof the code is
  -- yours.
  on conflict (phone) do update
    set name = excluded.name, updated_at = now()
    where usernames.username = excluded.username;
  return found;
exception
  when unique_violation then
    return false; -- the handle belongs to someone else
end $$;

revoke all on function public.claim_numberless(text, text, text) from public;
grant execute on function public.claim_numberless(text, text, text)
  to anon, authenticated;
