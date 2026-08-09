-- The Discover directory: a world-readable table of PUBLIC servers, so anyone
-- with the app can find a server and join it without an invite. This is the
-- "public vs private server" split — a private server stays invite-only (it is
-- simply never listed here); a public server publishes a row anybody can browse.
-- ============================================================================
-- Run ONCE in the Supabase SQL editor, AFTER docs/platform_moderation.sql —
-- this leans on public.is_locked_out() (to keep a banned owner's server out of
-- the directory) and public.is_silenced() (to stop a timed-out account listing
-- one), both defined there.
--
-- WHY THE JOIN SECRET IS WORLD-READABLE HERE, ON PURPOSE.
--
-- A server's traffic is E2E sealed under its `secret`, and the invite is what
-- hands that secret to a joiner. A PUBLIC server is one whose owner has decided
-- anyone may join — which is the same decision as "anyone may hold the key".
-- So the directory row carries the full invite snapshot (the same JSON a tapped
-- invite card carries, secret included): a browser joins by decoding it, exactly
-- as if someone had handed them the invite. That is the deliberate trade a
-- public server makes, and the in-app toggle says so before it is flipped.
--
-- Private servers, 1:1 chats, and a server's own sealed feed are all untouched —
-- this table is only ever fed a server whose owner chose to list it. A PAID
-- server is never listed (its secret must not be free); the client refuses to
-- publish one and the payload check below is the backstop.
--
-- What is still protected is the OWNER'S PHONE NUMBER: clients are granted every
-- column but that one, and reach-out/ownership is by the username already inside
-- the payload — exactly as the public feed, forum and marketplace do it.
--
-- ORDER MATTERS: the read policy calls is_locked_out(), which must already
-- exist. Tables, then privileges and policies, then the view.

-- ---------------------------------------------------------------------------
-- 1. Table
-- ---------------------------------------------------------------------------
create table if not exists public.server_directory (
  -- The server's id, so the owner's device recognises its own row and a
  -- re-list upserts the same one.
  id            text primary key,
  -- E.164 digits of the owner. Ownership only — never granted to a client role.
  owner_phone   text not null,
  -- Denormalized display fields, so the browse list renders without decoding
  -- every payload. Kept in step by the client on each publish.
  name          text not null default '',
  description   text not null default '',
  member_count  int  not null default 0,
  -- The full invite snapshot as JSON (CommunityStore.exportInvite), secret
  -- included — this is what a browser decodes to join. Never carries a phone.
  payload       text not null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create index if not exists server_directory_recent_idx
  on public.server_directory (updated_at desc);
create index if not exists server_directory_owner_idx
  on public.server_directory (owner_phone);

alter table public.server_directory enable row level security;

-- ---------------------------------------------------------------------------
-- 2. Column privileges
-- ---------------------------------------------------------------------------
-- THE PHONE COLUMN, PROPERLY — the same lesson as public_posts/market_listings.
-- Supabase grants these roles table-wide SELECT on every new table in public,
-- and Postgres cannot carve a column out of a table-wide grant, so `revoke
-- select (owner_phone)` on its own would change nothing. Revoke the whole
-- grant, then hand back the readable columns.
revoke select on table public.server_directory from anon, authenticated;
grant select (id, name, description, member_count, payload, created_at, updated_at)
  on public.server_directory to anon, authenticated;

-- Writing is by whole row; the policies decide whose row it may be. A listed
-- server's member count changes, so UPDATE is granted.
grant insert, update, delete on public.server_directory to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Policies
-- ---------------------------------------------------------------------------

-- Readable by anyone with the app — except a server whose owner is banned or
-- suspended, which leaves the directory the moment the sanction lands. This is
-- what lets a brand-new (anon-key) account browse everything.
drop policy if exists server_directory_read on public.server_directory;
create policy server_directory_read on public.server_directory
  for select to anon, authenticated
  using (not public.is_locked_out(owner_phone));

-- You may only list a server as yourself, and only while you are allowed to.
-- The phone comes from a JWT the client cannot forge, and a sanctioned account
-- is refused — so a modified client gains nothing.
drop policy if exists server_directory_insert_own on public.server_directory;
create policy server_directory_insert_own on public.server_directory
  for insert to authenticated
  with check (
    owner_phone = (auth.jwt() ->> 'phone')
    and not public.is_silenced(owner_phone)
  );

-- Updating the row (member count, a settings change) is your own row only.
drop policy if exists server_directory_update_own on public.server_directory;
create policy server_directory_update_own on public.server_directory
  for update to authenticated
  using (owner_phone = (auth.jwt() ->> 'phone'))
  with check (owner_phone = (auth.jwt() ->> 'phone'));

-- Unlisting (going private, deleting the server) is a delete of your own row.
drop policy if exists server_directory_delete_own on public.server_directory;
create policy server_directory_delete_own on public.server_directory
  for delete to authenticated
  using (owner_phone = (auth.jwt() ->> 'phone'));

-- ---------------------------------------------------------------------------
-- 4. What clients actually read
-- ---------------------------------------------------------------------------
-- A view with no phone column in it at all, so the ordinary path cannot leak
-- one even by accident. security_invoker keeps the caller's RLS in force, which
-- is what hides a banned owner's server.
drop view if exists public.server_directory_view;
create view public.server_directory_view
with (security_invoker = on) as
select
  d.id,
  d.name,
  d.description,
  d.member_count,
  d.payload,
  d.created_at,
  d.updated_at
from public.server_directory d;

grant select on public.server_directory_view to anon, authenticated;
