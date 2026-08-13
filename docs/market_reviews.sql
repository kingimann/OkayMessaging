-- Marketplace reviews, world-readable like the listings they attach to.
-- ============================================================================
-- Run ONCE in the Supabase SQL editor, AFTER docs/platform_moderation.sql
-- (is_locked_out/is_silenced) and docs/public_market.sql (the listing this
-- table's rows attach to — no foreign key enforced, since a review must
-- still exist even against a listing this device's own copy already
-- deleted).
--
-- WHY GLOBAL, LIKE LISTINGS. A review is an opinion about something
-- world-readable — the same public_feed/public_market rule applies: its
-- audience is everyone browsing the listing, so it has no key to seal
-- under. Same table shape as market_listings, on purpose, right down to
-- the phone-hiding trick.
--
-- THE BUG THIS FIXES. FeedStore.addReview built a review as a FeedPost
-- carrying `communityId: listing.communityId` — inherited from the
-- listing it reviews. Since the marketplace went global (2026-08-08), a
-- normal listing's communityId is '' (global-only), and
-- RelayService.sendFeedPost's dispatch had NO branch for a review: it is
-- not a listing (so it skips the market_listings publish), its communityId
-- resolves to no real Community (so it skips the sealed community bus),
-- and `if (post.communityId.isEmpty) return;` drops it on the floor. A
-- review only ever existed on the reviewer's own device — nobody else,
-- least of all the seller, ever saw it or was told about it.

create table if not exists public.market_reviews (
  -- The review's post id, client-generated (mirrors market_listings).
  id              text primary key,
  -- The listing being reviewed — FeedPost.parentId. Not a foreign key: a
  -- review must survive even against a listing already gone from this
  -- table (deleted, or never published because it predates this file).
  listing_id      text not null,
  -- E.164 digits. Ownership only — never granted to a client role below.
  author_phone    text not null,
  -- Public handle: how a reader knows who wrote it.
  author_username text not null default '',
  -- The whole review as the app's FeedPost JSON (rating, text,
  -- confirmedPurchase, authorVerified…), with the phone stripped before it
  -- ever leaves the device — same shape as a listing's payload.
  payload         text not null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create index if not exists market_reviews_listing_idx
  on public.market_reviews (listing_id, created_at desc);
create index if not exists market_reviews_author_idx
  on public.market_reviews (author_phone);

alter table public.market_reviews enable row level security;

-- ---------------------------------------------------------------------------
-- Column privileges — the same table-wide-grant trap market_listings and
-- public_posts already learned from: Supabase grants every new public table
-- SELECT to anon/authenticated by default, and `revoke select (col)` alone
-- changes nothing against a table-wide grant. Revoke everything, then hand
-- back only the columns that don't carry a phone.
-- ---------------------------------------------------------------------------
revoke select on table public.market_reviews from anon, authenticated;
grant select (id, listing_id, author_username, payload, created_at, updated_at)
  on public.market_reviews to anon, authenticated;

grant insert, update, delete on public.market_reviews to authenticated;

-- ---------------------------------------------------------------------------
-- Policies
-- ---------------------------------------------------------------------------

-- Readable by anyone with the app — except a review by an account that is
-- banned or suspended, which leaves the marketplace the moment the sanction
-- lands, same as a listing does.
drop policy if exists market_reviews_read on public.market_reviews;
create policy market_reviews_read on public.market_reviews
  for select to anon, authenticated
  using (not public.is_locked_out(author_phone));

-- You may only review as yourself, and only while you are allowed to post.
-- The phone comes from a JWT the client cannot forge.
drop policy if exists market_reviews_insert_own on public.market_reviews;
create policy market_reviews_insert_own on public.market_reviews
  for insert to authenticated
  with check (
    author_phone = (auth.jwt() ->> 'phone')
    and not public.is_silenced(author_phone)
  );

-- addReview rewrites a review by deleting the old one and posting a new id
-- in its place, so UPDATE isn't exercised by the client today — granted
-- anyway, own-row-only, so it isn't a silent gap if that ever changes.
drop policy if exists market_reviews_update_own on public.market_reviews;
create policy market_reviews_update_own on public.market_reviews
  for update to authenticated
  using (author_phone = (auth.jwt() ->> 'phone'))
  with check (author_phone = (auth.jwt() ->> 'phone'));

drop policy if exists market_reviews_delete_own on public.market_reviews;
create policy market_reviews_delete_own on public.market_reviews
  for delete to authenticated
  using (author_phone = (auth.jwt() ->> 'phone'));

-- ---------------------------------------------------------------------------
-- What clients actually read: a view with no phone column at all, so the
-- ordinary path cannot leak one even by accident. security_invoker keeps the
-- caller's own RLS in force, which is what hides a banned author's reviews.
-- ---------------------------------------------------------------------------
drop view if exists public.market_reviews_view;
create view public.market_reviews_view
with (security_invoker = on) as
select
  r.id,
  r.listing_id,
  r.author_username,
  r.payload,
  r.created_at,
  r.updated_at
from public.market_reviews r;

grant select on public.market_reviews_view to anon, authenticated;
