-- Reachability choices on the public directory.
-- ============================================================================
-- Run ONCE in the Supabase SQL editor.
--
-- WHY. The app offers two doors to a person: their phone number (contact
-- sync matches hashed numbers) and their profile (username search). These
-- columns let each account choose which doors are open. Both default open —
-- that is the behaviour everyone already has.
--
-- The flags are honoured by the app's directory queries. Like the rest of
-- this project's client-side rules, a modified client could ignore them;
-- what they protect against is being *listed*, not being contacted by
-- someone who already knows you.

alter table public.usernames
  add column if not exists find_by_username boolean not null default true;
alter table public.usernames
  add column if not exists find_by_phone boolean not null default true;
