-- The global marketplace: a world-readable table of for-sale listings that lives
-- OUTSIDE any server, so ANY user — including a brand-new account in no servers,
-- or someone who joined a server after an item was posted — can find them.
-- ============================================================================
-- Run ONCE in the Supabase SQL editor, AFTER docs/platform_moderation.sql —
-- this leans on public.is_locked_out() (to keep banned sellers' listings out)
-- and public.is_silenced() (to stop a timed-out account posting), both defined
-- there.
--
-- WHY THIS IS PLAINTEXT THE SERVER CAN READ, like the public feed and forum.
--
-- A marketplace listing is an ADVERTISEMENT: the seller wants strangers to find
-- it and buy. Its audience is everyone with the app, and a board whose audience
-- is everyone has no key to seal under — a public key is the same as no key. So
-- the rule here is the public feed's rule: what is posted to the marketplace is
-- public. Private messaging, chats, and a server's own sealed feed are all
-- untouched — this table is only ever fed the listing a seller chose to post.
--
-- Servers' own copies (community_posts, sealed under the community secret) still
-- exist for members; this GLOBAL table is what makes the marketplace visible to
-- people who are not in the seller's server.
--
-- What is still protected is the seller's PHONE NUMBER: clients are granted the
-- other columns and never that one, attribution and reach-out are by username
-- (already public in the directory, and how the app resolves a seller to message
-- or pay them), exactly as the public feed and forum do it.
--
-- ORDER MATTERS: the read policy calls is_locked_out(), which must already
-- exist. Tables, then privileges and policies, then the view.

-- ---------------------------------------------------------------------------
-- 1. Table
-- ---------------------------------------------------------------------------
create table if not exists public.market_listings (
  -- The listing's post id, client-generated, so a device recognises its own
  -- listing coming back and an edit upserts the same row.
  id              text primary key,
  -- E.164 digits. Ownership only — never granted to a client role below.
  author_phone    text not null,
  -- Public handle: how a buyer resolves the seller to message or pay them.
  author_username text not null default '',
  -- The full listing as the app's FeedPost JSON, with the phone stripped out
  -- before it ever leaves the device. Everything the marketplace renders — the
  -- price, photos, category, condition, place, attributes — is in here.
  payload         text not null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create index if not exists market_listings_recent_idx
  on public.market_listings (updated_at desc);
create index if not exists market_listings_author_idx
  on public.market_listings (author_phone);

alter table public.market_listings enable row level security;

-- ---------------------------------------------------------------------------
-- 2. Column privileges
-- ---------------------------------------------------------------------------
-- THE PHONE COLUMN, PROPERLY — the same lesson as public_posts/public_forum.
-- Supabase grants these roles table-wide SELECT on every new table in public,
-- and Postgres cannot carve a column out of a table-wide grant, so `revoke
-- select (author_phone)` on its own changes nothing and leaves every seller's
-- number readable. Revoke the whole grant, then hand back the readable columns.
revoke select on table public.market_listings from anon, authenticated;
grant select (id, author_username, payload, created_at, updated_at)
  on public.market_listings to anon, authenticated;

-- Writing is by whole row; the policies decide whose row it may be. A listing
-- can be edited (price drop, sold flag) so UPDATE is granted, unlike the
-- append-only public feed.
grant insert, update, delete on public.market_listings to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Policies
-- ---------------------------------------------------------------------------

-- Readable by anyone with the app — except listings by an account that is
-- banned or suspended, which leave the marketplace the moment the sanction
-- lands. This is what lets a brand-new (anon-key) account browse everything.
drop policy if exists market_listings_read on public.market_listings;
create policy market_listings_read on public.market_listings
  for select to anon, authenticated
  using (not public.is_locked_out(author_phone));

-- You may only post as yourself, and only while you are allowed to. The phone
-- comes from a JWT the client cannot forge, and a sanctioned account is refused
-- — so a modified client gains nothing.
drop policy if exists market_listings_insert_own on public.market_listings;
create policy market_listings_insert_own on public.market_listings
  for insert to authenticated
  with check (
    author_phone = (auth.jwt() ->> 'phone')
    and not public.is_silenced(author_phone)
  );

-- Editing a listing (price, sold) is an UPDATE of your own row only.
drop policy if exists market_listings_update_own on public.market_listings;
create policy market_listings_update_own on public.market_listings
  for update to authenticated
  using (author_phone = (auth.jwt() ->> 'phone'))
  with check (author_phone = (auth.jwt() ->> 'phone'));

drop policy if exists market_listings_delete_own on public.market_listings;
create policy market_listings_delete_own on public.market_listings
  for delete to authenticated
  using (author_phone = (auth.jwt() ->> 'phone'));

-- ---------------------------------------------------------------------------
-- 4. What clients actually read
-- ---------------------------------------------------------------------------
-- A view with no phone column in it at all, so the ordinary path cannot leak
-- one even by accident. security_invoker keeps the caller's RLS in force, which
-- is what hides a banned seller's listings.
drop view if exists public.market_listings_view;
create view public.market_listings_view
with (security_invoker = on) as
select
  m.id,
  m.author_username,
  m.payload,
  m.created_at,
  m.updated_at
from public.market_listings m;

grant select on public.market_listings_view to anon, authenticated;
