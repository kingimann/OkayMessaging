-- Temporary deactivation for the people directory.
-- ============================================================================
-- Run ONCE in the Supabase SQL editor, AFTER docs/directory_numberless.sql
-- (this replaces its find_people with one more filter).
--
-- WHY. "Deactivate my account" has to mean something on the server, or it
-- means nothing: the app can sign somebody out locally, but their @handle
-- stayed findable by everyone. The `hidden` flag is that meaning — a hidden
-- row answers no search, while the handle stays THEIRS (the row keeps
-- existing, so nobody can take the name while they're away). Reactivation is
-- signing back in: the app clears the flag through the same own-row RLS
-- update that set it.
--
-- Deletion is not here on purpose: deleting an account also has to delete
-- the AUTH user, which no RLS policy can do — that is the delete-account
-- Edge Function (service role), which removes every phone-keyed row and the
-- user itself.

alter table public.usernames
  add column if not exists hidden boolean not null default false;

-- The same function docs/directory_numberless.sql installs, with one more
-- line: hidden rows answer no search — not by handle, not by anyone.
-- A DROP first, because the return type has changed since this file was
-- written (docs/public_profiles.sql widened it to carry a profile) and
-- `create or replace` cannot change one — re-running the migrations in order
-- fails outright without this. Harmless on a fresh project.
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
    select u.phone, u.username, u.name, coalesce(u.verified, false)
    from public.usernames u
    -- '_' is a legal handle character but a LIKE wildcard; escape it so
    -- searching a_b does not match axb.
    where lower(u.username) like replace(q, '_', '\_') || '%'
      and coalesce(u.find_by_username, true)
      and not coalesce(u.hidden, false)
      and not public.is_locked_out(u.phone)
    order by u.username
    limit 25;
end $$;

revoke all on function public.find_people(text) from public;
grant execute on function public.find_people(text) to anon, authenticated;
