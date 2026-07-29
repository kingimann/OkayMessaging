-- Make yourself the app-wide owner.
-- ============================================================================
-- Run in the Supabase SQL editor. Safe to run repeatedly.
--
-- WHY THIS FILE EXISTS. The grant at the bottom of platform_moderation.sql
-- makes you type your number, and the app only ever matches on E.164 digits
-- with no '+' and no spaces. A row saying '+1 555 123 4567' looks right and
-- matches nothing, so the console stays hidden with no error to explain it.
-- These statements read the number back out of auth.users instead, so the
-- stored value is whatever your account actually verified.

-- ---------------------------------------------------------------------------
-- STEP 1. Which accounts exist, and what phone did each verify?
-- ---------------------------------------------------------------------------
-- Run this on its own first. The `digits` column is exactly what the app
-- compares against. An account with a null phone cannot hold a role at all:
-- every Edge Function identifies its caller by the verified phone in the JWT.
select
  u.id,
  u.phone                                    as stored_phone,
  regexp_replace(coalesce(u.phone, ''), '\D', '', 'g') as digits,
  u.email,
  u.phone_confirmed_at,
  u.last_sign_in_at
from auth.users u
order by u.last_sign_in_at desc nulls last;

-- ---------------------------------------------------------------------------
-- STEP 2. Grant owner to one of those accounts.
-- ---------------------------------------------------------------------------
-- Put YOUR number between the quotes below — any format is fine, spaces,
-- dashes and a leading '+' are all stripped before matching. What gets stored
-- is the digits from auth.users, not what you type here.
--
-- If this reports "0 rows", the number matched no account: check STEP 1 and
-- try the digits shown there.

insert into public.platform_roles (phone, role, granted_by)
select
  regexp_replace(u.phone, '\D', '', 'g'),
  'owner',
  'bootstrap'
from auth.users u
where u.phone is not null
  and regexp_replace(u.phone, '\D', '', 'g')
      = regexp_replace('+1 555 123 4567', '\D', '', 'g')   -- <<< EDIT THIS
on conflict (phone) do update set role = 'owner';

-- ---------------------------------------------------------------------------
-- STEP 3. Confirm it took.
-- ---------------------------------------------------------------------------
-- Expect one row, role 'owner', phone as bare digits. If this is empty, STEP 2
-- matched nothing.
select phone, role, granted_by, created_at
from public.platform_roles
order by role;

-- ---------------------------------------------------------------------------
-- Then: sign out and back in on the phone.
-- ---------------------------------------------------------------------------
-- The role is read with the JWT the app holds. A session minted before the
-- grant carries the same phone, so a fresh sign-in is not strictly required —
-- but the app only asks for its role at startup, so restart it at minimum.
-- Settings should then show a "Moderation" section.

-- ---------------------------------------------------------------------------
-- Escape hatch: no phone on any account?
-- ---------------------------------------------------------------------------
-- If STEP 1 shows your account with a null phone, you signed in by email only
-- and no Edge Function can identify you — callerPhone() reads the phone claim
-- and nothing else. Sign in on the app with your number first (that is what
-- creates the phone on the auth user), then come back to STEP 1.
