-- Shadow bans and area bans (2026-08-09). Run AFTER docs/platform_moderation.sql,
-- docs/public_feed.sql, docs/public_market.sql, docs/public_forum.sql,
-- docs/community_notes.sql and docs/public_servers.sql — it re-creates read and
-- insert policies those files define.
--
-- Until now moderation had one blunt setting: a whole account, banned or
-- timed out everywhere. Two things were missing.
--
--   * A SHADOW BAN. The account carries on exactly as before — it can post,
--     and it sees its own posts in place — but nobody else does. It is the
--     answer to the spammer who simply signs up again the moment they are
--     told they are banned, and it works only because they are NOT told.
--
--   * AREA BANS. Somebody scamming in the marketplace should lose the
--     marketplace, not their conversations. One row per (account, area), so
--     a seller can be barred from selling while still using the forum.
--
-- WHAT A SHADOW BAN IS NOT: it does not hide the account's MESSAGES. Chats
-- are end-to-end encrypted and delivered device to device — the server could
-- not filter them if it wanted to, and would have to break the encryption to
-- try. It hides what is PUBLIC: feed posts, listings, forum posts and
-- comments, community notes, and a listed server. Say that plainly rather
-- than implying a reach this does not have.
-- ---------------------------------------------------------------------------

-- 'shadow' joins the existing kinds. It is deliberately NOT in is_locked_out:
-- a shadow-banned account is not locked out of anything, which is the point.
alter table public.account_sanctions drop constraint if exists account_sanctions_kind_check;
alter table public.account_sanctions add constraint account_sanctions_kind_check
  check (kind in ('timeout', 'suspend', 'ban', 'shadow'));

-- One row per account per area they are barred from.
create table if not exists public.account_area_bans (
  phone       text not null,
  area        text not null check (area in ('marketplace','servers','forum','feed')),
  reason      text not null default '' check (char_length(reason) <= 500),
  until       timestamptz,                  -- null = indefinite
  actor_phone text not null default '',
  created_at  timestamptz not null default now(),
  primary key (phone, area)
);
alter table public.account_area_bans enable row level security;

-- Readable, like account_sanctions: a barred device has to be able to say
-- WHY the marketplace refused it, and every device must agree. Written only
-- by moderation-act (service role), which checks the caller's rank first.
drop policy if exists account_area_bans_read on public.account_area_bans;
create policy account_area_bans_read on public.account_area_bans
  for select to anon, authenticated using (true);

create index if not exists account_area_bans_until_idx
  on public.account_area_bans (until);

-- ---------------------------------------------------------------------------
-- The three predicates every policy below is built from
-- ---------------------------------------------------------------------------
create or replace function public.is_shadow_banned(p text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.account_sanctions s
     where s.phone = p
       and s.kind = 'shadow'
       and (s.until is null or s.until > now())
  );
$$;

-- is_silenced matched ANY active sanction row, whatever its kind. Adding
-- 'shadow' to that table therefore silenced the account — refusing its posts,
-- which is precisely how a shadow-banned person finds out they are shadow
-- banned. Exclude it: a shadow ban must change nothing the target can see.
-- Every existing write policy already calls this, so they all pick it up.
create or replace function public.is_silenced(p text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.account_sanctions s
     where s.phone = p
       and s.kind <> 'shadow'
       and (s.until is null or s.until > now())
  );
$$;

create or replace function public.is_area_banned(p text, a text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.account_area_bans b
     where b.phone = p
       and b.area = a
       and (b.until is null or b.until > now())
  );
$$;

-- Whether an author's public content is visible to the CALLER.
--
-- The self-exception is the whole mechanism of a shadow ban: the author still
-- sees their own posts exactly where they left them, so nothing tells them to
-- go and make another account.
create or replace function public.content_visible(author text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select not public.is_locked_out(author)
     and (
       author = (auth.jwt() ->> 'phone')
       or not public.is_shadow_banned(author)
     );
$$;

grant execute on function public.is_shadow_banned(text) to anon, authenticated;
grant execute on function public.is_area_banned(text, text) to anon, authenticated;
grant execute on function public.content_visible(text) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Reads: a shadow-banned author's public content disappears for everyone else
-- ---------------------------------------------------------------------------
drop policy if exists public_posts_read on public.public_posts;
create policy public_posts_read on public.public_posts
  for select to anon, authenticated
  using (public.content_visible(author_phone));

drop policy if exists market_listings_read on public.market_listings;
create policy market_listings_read on public.market_listings
  for select to anon, authenticated
  using (public.content_visible(author_phone));

drop policy if exists public_forum_posts_read on public.public_forum_posts;
create policy public_forum_posts_read on public.public_forum_posts
  for select to anon, authenticated
  using (public.content_visible(author_phone));

drop policy if exists public_forum_comments_read on public.public_forum_comments;
create policy public_forum_comments_read on public.public_forum_comments
  for select to anon, authenticated
  using (public.content_visible(author_phone));

drop policy if exists community_notes_read on public.community_notes;
create policy community_notes_read on public.community_notes
  for select to anon, authenticated
  using (public.content_visible(author_phone));

drop policy if exists server_directory_read on public.server_directory;
create policy server_directory_read on public.server_directory
  for select to anon, authenticated
  using (public.content_visible(owner_phone));

-- ---------------------------------------------------------------------------
-- Writes: an area ban refuses new content in THAT area only
-- ---------------------------------------------------------------------------
-- Each of these is the policy that already existed, plus one clause. A
-- shadow-banned account is NOT stopped from writing — being stopped is how
-- you find out.
drop policy if exists public_posts_insert_own on public.public_posts;
create policy public_posts_insert_own on public.public_posts
  for insert to authenticated
  with check (
    author_phone = (auth.jwt() ->> 'phone')
    and not public.is_silenced(author_phone)
    and not public.is_area_banned(author_phone, 'feed')
  );

drop policy if exists market_listings_insert_own on public.market_listings;
create policy market_listings_insert_own on public.market_listings
  for insert to authenticated
  with check (
    author_phone = (auth.jwt() ->> 'phone')
    and not public.is_silenced(author_phone)
    and not public.is_area_banned(author_phone, 'marketplace')
  );

drop policy if exists public_forum_posts_insert_own on public.public_forum_posts;
create policy public_forum_posts_insert_own on public.public_forum_posts
  for insert to authenticated
  with check (
    author_phone = (auth.jwt() ->> 'phone')
    and not public.is_silenced(author_phone)
    and not public.is_area_banned(author_phone, 'forum')
  );

drop policy if exists public_forum_comments_insert_own on public.public_forum_comments;
create policy public_forum_comments_insert_own on public.public_forum_comments
  for insert to authenticated
  with check (
    author_phone = (auth.jwt() ->> 'phone')
    and not public.is_silenced(author_phone)
    and not public.is_area_banned(author_phone, 'forum')
  );

drop policy if exists community_notes_insert_own on public.community_notes;
create policy community_notes_insert_own on public.community_notes
  for insert to authenticated
  with check (
    author_phone = (auth.jwt() ->> 'phone')
    and not public.is_silenced(author_phone)
    and not public.is_area_banned(author_phone, 'feed')
  );

drop policy if exists server_directory_insert_own on public.server_directory;
create policy server_directory_insert_own on public.server_directory
  for insert to authenticated
  with check (
    owner_phone = (auth.jwt() ->> 'phone')
    and not public.is_silenced(owner_phone)
    and not public.is_area_banned(owner_phone, 'servers')
  );

-- ---------------------------------------------------------------------------
-- What a barred account is allowed to know about itself
-- ---------------------------------------------------------------------------
-- Its own area bans, so the app can say "you can't sell here" with a reason.
-- Deliberately NOT its shadow ban: an endpoint that answers "am I shadow
-- banned?" is a shadow ban that does not work.
create or replace function public.my_area_bans()
returns table (area text, reason text, until timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  select b.area, b.reason, b.until
    from public.account_area_bans b
   where b.phone = (auth.jwt() ->> 'phone')
     and (b.until is null or b.until > now());
$$;

grant execute on function public.my_area_bans() to authenticated;
