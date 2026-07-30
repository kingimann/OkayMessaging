-- The public newsfeed: posts anyone can read, anyone signed in can write.
-- ============================================================================
-- Run ONCE in the Supabase SQL editor. Requires docs/platform_moderation.sql
-- first — this leans on public.is_locked_out() to keep banned accounts out of
-- the feed.
--
-- WHAT IS DIFFERENT ABOUT THIS TABLE, SAID PLAINLY.
--
-- Everything else in this app is either on the device or sealed before it
-- leaves: private messages are end-to-end encrypted, server posts and listings
-- are encrypted with their server's key, and the mailbox holds only ciphertext.
-- This table is the first thing that holds **plaintext the server can read**,
-- and that is not a weakening of the promise — it is what "public" means. A
-- post whose audience is everyone cannot be encrypted to everyone; the key
-- would have to be public, which is the same as no key.
--
-- So the rule for this table is different and worth stating: **anything posted
-- here is public.** Not "private unless shared" — public, permanently, to
-- anybody with the app. Private messaging is untouched by this file.
--
-- What is still protected: the author's phone number. A public feed that
-- printed a phone number next to every post would make harvesting them
-- trivial, so the column exists for ownership checks and is revoked from every
-- client role. Posts are attributed by username, which is already public in
-- the directory.

-- ---------------------------------------------------------------------------
-- Whether an account may post right now
-- ---------------------------------------------------------------------------
-- A time-out silences without hiding: the posts stay up, no new ones land.
-- A ban or suspension does both, via is_locked_out in the read policy above.
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
       and (s.until is null or s.until > now())
  );
$$;

-- ---------------------------------------------------------------------------
-- Counters that see past the like policy
-- ---------------------------------------------------------------------------
create or replace function public.public_post_like_count(p text)
returns bigint
language sql
stable
security definer
set search_path = public
as $$
  select count(*) from public.public_post_likes where post_id = p;
$$;

create or replace function public.public_post_reply_count(p text)
returns bigint
language sql
stable
security definer
set search_path = public
as $$
  select count(*) from public.public_posts where reply_to = p;
$$;

-- ---------------------------------------------------------------------------
-- Posts
-- ---------------------------------------------------------------------------
create table if not exists public.public_posts (
  -- Client-generated, so a device recognises its own post coming back.
  id            text primary key,
  -- E.164 digits. Ownership only: SELECT on this column is revoked below.
  author_phone  text not null,
  author_username text not null default '',
  author_name   text not null default '',
  -- Self-attested, exactly like the badge on a chat message. The directory's
  -- server-written `verified` column is the stronger claim; this is for
  -- rendering without a join.
  author_verified boolean not null default false,
  body          text not null check (char_length(body) between 1 and 500),
  -- A reply points at its parent; deleting a post takes its replies with it.
  reply_to      text references public.public_posts(id) on delete cascade,
  created_at    timestamptz not null default now()
);

create index if not exists public_posts_recent_idx
  on public.public_posts (created_at desc);
create index if not exists public_posts_replies_idx
  on public.public_posts (reply_to, created_at);
create index if not exists public_posts_author_idx
  on public.public_posts (author_phone);

alter table public.public_posts enable row level security;

-- The phone is for ownership, never for reading. Postgres enforces this per
-- column, so a client asking for it is refused rather than trusted not to ask.
revoke select (author_phone) on public.public_posts from anon, authenticated;

-- Readable by anyone with the app — except posts by an account that is banned
-- or suspended, which leave the feed the moment the sanction lands.
drop policy if exists public_posts_read on public.public_posts;
create policy public_posts_read on public.public_posts
  for select to anon, authenticated
  using (not public.is_locked_out(author_phone));

-- You may only post as yourself, and only while you are allowed to post. Both
-- halves are enforced here, so a modified client gains nothing: the phone comes
-- from a JWT it cannot forge, and a sanctioned account is refused outright.
drop policy if exists public_posts_insert_own on public.public_posts;
create policy public_posts_insert_own on public.public_posts
  for insert to authenticated
  with check (
    author_phone = (auth.jwt() ->> 'phone')
    and not public.is_silenced(author_phone)
  );

-- Deleting your own post. No update policy at all: an edited public post with
-- no history is a way to bait people and then rewrite it.
drop policy if exists public_posts_delete_own on public.public_posts;
create policy public_posts_delete_own on public.public_posts
  for delete to authenticated
  using (author_phone = (auth.jwt() ->> 'phone'));

-- ---------------------------------------------------------------------------
-- Likes
-- ---------------------------------------------------------------------------
create table if not exists public.public_post_likes (
  post_id     text not null references public.public_posts(id) on delete cascade,
  liker_phone text not null,
  created_at  timestamptz not null default now(),
  primary key (post_id, liker_phone)
);

alter table public.public_post_likes enable row level security;
revoke select (liker_phone) on public.public_post_likes from anon, authenticated;

-- You can see which posts YOU liked, and nobody else's likes. Who liked what
-- is nobody's business; the totals come from the counter below, which runs
-- above RLS precisely so it can count rows this policy hides.
drop policy if exists public_post_likes_read_own on public.public_post_likes;
create policy public_post_likes_read_own on public.public_post_likes
  for select to authenticated
  using (liker_phone = (auth.jwt() ->> 'phone'));

drop policy if exists public_post_likes_insert_own on public.public_post_likes;
create policy public_post_likes_insert_own on public.public_post_likes
  for insert to authenticated
  with check (
    liker_phone = (auth.jwt() ->> 'phone')
    and not public.is_silenced(liker_phone)
  );

drop policy if exists public_post_likes_delete_own on public.public_post_likes;
create policy public_post_likes_delete_own on public.public_post_likes
  for delete to authenticated
  using (liker_phone = (auth.jwt() ->> 'phone'));

-- ---------------------------------------------------------------------------
-- What clients actually read
-- ---------------------------------------------------------------------------
-- A view with no phone column in it at all, so the ordinary path cannot leak
-- one even by accident. security_invoker keeps the caller's RLS in force, which
-- is what hides a banned author's posts.
create or replace view public.public_feed
with (security_invoker = on) as
select
  p.id,
  p.author_username,
  p.author_name,
  p.author_verified,
  p.body,
  p.reply_to,
  p.created_at,
  public.public_post_like_count(p.id)  as like_count,
  public.public_post_reply_count(p.id) as reply_count
from public.public_posts p;

grant select on public.public_feed to anon, authenticated;
