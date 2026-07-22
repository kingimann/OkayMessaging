-- Okay Messaging — minimal identity registry
-- =============================================
-- Run this ONCE in your Supabase project: Dashboard → SQL Editor → paste →
-- Run. It creates the ONLY server-side data the app keeps: the mapping from a
-- verified phone number to its chosen username, used to (a) check whether a
-- username is available and (b) tell which username is linked to a number.
--
-- No messages, calls, media, or chats are ever stored on the server. Those are
-- relayed live between devices (Supabase Realtime broadcast) and kept only in
-- each device's local storage, so they're gone when the app is deleted.

create table if not exists public.usernames (
  phone      text primary key,           -- E.164 digits, e.g. 15551234567
  username   text not null,
  updated_at timestamptz not null default now()
);

-- Case-insensitive uniqueness: "Ada" and "ada" are the same username.
create unique index if not exists usernames_username_lower_idx
  on public.usernames (lower(username));

alter table public.usernames enable row level security;

-- Only a phone that has verified via SMS OTP (an authenticated user) can read
-- the registry to check availability...
drop policy if exists usernames_read on public.usernames;
create policy usernames_read on public.usernames
  for select to authenticated using (true);

-- ...and a user may only claim / change the row for their OWN verified number.
-- Supabase puts the verified phone in the JWT as `phone` (E.164 digits).
drop policy if exists usernames_insert_own on public.usernames;
create policy usernames_insert_own on public.usernames
  for insert to authenticated
  with check (phone = (auth.jwt() ->> 'phone'));

drop policy if exists usernames_update_own on public.usernames;
create policy usernames_update_own on public.usernames
  for update to authenticated
  using (phone = (auth.jwt() ->> 'phone'))
  with check (phone = (auth.jwt() ->> 'phone'));
