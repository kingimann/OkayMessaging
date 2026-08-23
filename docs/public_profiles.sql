-- Public-by-default profiles (2026-08-23), continuing the owner's direction:
-- "move away from privacy and storing things local and be more social media".
--
-- WHAT WAS WRONG. Browsing people barely worked. The directory carried a
-- handle, a display name and a verified flag and NOTHING else — no avatar, no
-- bio, no location — so a stranger in search results, or on a profile you
-- opened from a public post, drew as coloured initials with an @handle under
-- them. `knownUserFor` could only ever answer for yourself or somebody you
-- had already chatted with, which is exactly the person you are NOT looking
-- at when you are trying to find somebody new.
--
-- WHAT THIS PUBLISHES, and it is a real disclosure rather than a schema
-- tidy-up: the avatar bundle, the bio, the location and the business chip
-- become world-readable for anyone holding the publishable key. That is the
-- deliberate trade — it is what makes a social app's people search work at
-- all — and the app says so on the screen where somebody edits them.
--
-- WHAT IT DOES NOT PUBLISH, and this is load-bearing:
--
-- * THE PHONE NUMBER. docs/directory_phone_privacy.sql (2026-08-10) closed a
--   real hole where a two-character prefix answered 25 rows carrying real
--   E.164 numbers, so ~1,300 anon queries walked the handle space collecting
--   them. Every rule from that file is preserved below, verbatim in effect:
--   a PREFIX match is a browsing result and gets no number, only an EXACT
--   handle is answered with one (sign-in by username needs it, signed out).
--   Nothing here widens that by a character.
-- * pronouns and links, which were removed from the profile UI entirely on
--   2026-08-17 at the owner's call. Publishing a field the app no longer
--   lets anybody edit would be publishing stale data nobody can correct.
--
-- FIND_PEOPLE IS NOW DEFINED FOUR TIMES across the migrations —
-- directory_numberless.sql, then account_lifecycle.sql (adds the `hidden`
-- filter), then directory_phone_privacy.sql (the phone rule), then here.
-- CLAUDE.md's own warning applies and is the reason this file is written the
-- way it is: replacing it without copying every earlier condition quietly
-- reactivates everybody who deactivated, or hands out numbers again. All
-- four conditions are carried below and check_sql.sh asserts each of them
-- STILL holds after this file is applied, not merely that the new columns
-- arrived.

alter table public.usernames add column if not exists avatar_color text not null default '';
alter table public.usernames add column if not exists avatar_color2 text not null default '';
alter table public.usernames add column if not exists emoji text not null default '';
alter table public.usernames add column if not exists avatar_seed text not null default '';
alter table public.usernames add column if not exists avatar_face text not null default '';
alter table public.usernames add column if not exists avatar_gif text not null default '';
alter table public.usernames add column if not exists about text not null default '';
alter table public.usernames add column if not exists location text not null default '';
alter table public.usernames add column if not exists is_business boolean not null default false;
alter table public.usernames add column if not exists business_category text not null default '';

-- The search. Every condition from all three earlier definitions is here:
-- the handle shape guard, find_by_username, hidden (account_lifecycle), the
-- lock-out check, and the exact-handle-only phone rule.
-- The return type gains columns, and `create or replace` cannot change one —
-- it fails outright with "cannot change return type of existing function".
-- The same wall `public_follow` hit when it started returning a boolean, and
-- the reason that one is dropped first too. Caught by check_sql.sh's
-- re-apply pass, which is exactly what that second loop is for.
--
-- A drop hands the new function FRESH default privileges, so the grants
-- below are not decoration: on a Supabase project the defaults would give
-- anon EXECUTE anyway, but relying on that is how the opposite mistake
-- (find_people_by_hashes coming out anon-callable) happened. State it.
drop function if exists public.find_people(text);
create function public.find_people(q text)
returns table (
  phone text, username text, name text, verified boolean,
  avatar_color text, avatar_color2 text, emoji text, avatar_seed text,
  avatar_face text, avatar_gif text, about text, location text,
  is_business boolean, business_category text)
language plpgsql security definer set search_path = public as $$
begin
  -- Handle-shaped queries only; anything else could smuggle LIKE wildcards.
  if q is null or q !~ '^[a-z0-9_.]{2,32}$' then
    return;
  end if;
  return query
    select
      -- UNCHANGED from directory_phone_privacy.sql, and the reason this
      -- function is rewritten by hand rather than patched: a prefix match is
      -- a browsing result and gets no number; only somebody who typed the
      -- handle exactly — which is what signing in and opening a chat both do
      -- — is answered with one.
      case when lower(u.username) = q then u.phone else '' end,
      u.username,
      u.name,
      coalesce(u.verified, false),
      coalesce(u.avatar_color, ''),
      coalesce(u.avatar_color2, ''),
      coalesce(u.emoji, ''),
      coalesce(u.avatar_seed, ''),
      coalesce(u.avatar_face, ''),
      coalesce(u.avatar_gif, ''),
      coalesce(u.about, ''),
      coalesce(u.location, ''),
      coalesce(u.is_business, false),
      coalesce(u.business_category, '')
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

-- One person's profile, by exact handle — what opening a stranger's profile
-- asks for. Deliberately returns NO phone at all, not even on an exact
-- match: find_people already answers that question for the one caller that
-- needs it (sign-in, and opening a chat), and a second door handing out
-- numbers is how the 2026-08-10 hole would grow back.
create or replace function public.public_profile(uname text)
returns table (
  username text, name text, verified boolean,
  avatar_color text, avatar_color2 text, emoji text, avatar_seed text,
  avatar_face text, avatar_gif text, about text, location text,
  is_business boolean, business_category text)
language plpgsql stable security definer set search_path = public as $$
declare q text := lower(coalesce(uname, ''));
begin
  if q !~ '^[a-z0-9_.]{2,32}$' then
    return;
  end if;
  return query
    select
      u.username, u.name, coalesce(u.verified, false),
      coalesce(u.avatar_color, ''), coalesce(u.avatar_color2, ''),
      coalesce(u.emoji, ''), coalesce(u.avatar_seed, ''),
      coalesce(u.avatar_face, ''), coalesce(u.avatar_gif, ''),
      coalesce(u.about, ''), coalesce(u.location, ''),
      coalesce(u.is_business, false), coalesce(u.business_category, '')
    from public.usernames u
    where lower(u.username) = q
      and coalesce(u.find_by_username, true)
      and not coalesce(u.hidden, false)
      and not public.is_locked_out(u.phone)
    limit 1;
end $$;

revoke all on function public.public_profile(text) from public;
grant execute on function public.public_profile(text) to anon, authenticated;

-- The write side needs nothing new. usernames_read still scopes SELECT on the
-- table to the caller's OWN row, and the existing insert/update policies
-- already let an account write that row — so publishing a profile is the app
-- upserting its own row with more columns in it, checked by the same RLS that
-- has always governed it. A client cannot write anybody else's profile.
