-- The public newsfeed: posts anyone can read, anyone signed in can write.
-- ============================================================================
-- Run ONCE in the Supabase SQL editor, AFTER docs/platform_moderation.sql —
-- this leans on public.is_locked_out() to keep banned accounts out of the feed.
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
-- trivial, so clients are granted the other columns and never that one. Posts
-- are attributed by username, which is already public in the directory.
--
-- ORDER MATTERS HERE, in both directions:
--   * a SQL function's body is parsed when it is created, so the tables it
--     reads must exist first;
--   * a policy resolves the functions it calls when it is created, so those
--     must exist before the policies.
-- Hence: tables, then functions, then privileges and policies, then the view.

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------
create table if not exists public.public_posts (
  -- Client-generated, so a device recognises its own post coming back.
  id            text primary key,
  -- E.164 digits. Ownership only — never granted to a client role below.
  author_phone  text not null,
  author_username text not null default '',
  author_name   text not null default '',
  -- Self-attested, exactly like the badge on a chat message. The directory's
  -- server-written `verified` column is the stronger claim; this is for
  -- rendering without a join.
  author_verified boolean not null default false,
  -- Empty is allowed only when the post carries an image or is a plain
  -- repost; the check below spells that out.
  body          text not null default '' check (char_length(body) <= 500),
  -- A reply points at its parent; deleting a post takes its replies with it.
  reply_to      text references public.public_posts(id) on delete cascade,
  -- A repost points at what it repeats. With a body it reads as a quote post,
  -- without one as a plain repost. Deleting the original takes the reposts:
  -- a repost of nothing is not a post.
  repost_of     text references public.public_posts(id) on delete cascade,
  -- Path inside the public-media bucket, not a full URL, so moving the project
  -- doesn't strand every image ever posted.
  image_path    text not null default '',
  -- A poll: two to four answers, with the question in `body`. Null for an
  -- ordinary post. Who voted for what is in public_post_votes and is readable
  -- by nobody; only the tally comes back, from the counter below.
  poll_options  text[],
  poll_closes_at timestamptz,
  created_at    timestamptz not null default now(),
  -- Something has to be in a post. Text, an image, or a repost — an entirely
  -- empty row is a rendering bug waiting to happen.
  constraint public_posts_not_empty check (
    char_length(body) > 0 or image_path <> '' or repost_of is not null
  ),
  -- A post cannot be both a reply and a repost: the two mean different places
  -- in the tree and the UI would have to pick one anyway.
  constraint public_posts_reply_xor_repost check (
    reply_to is null or repost_of is null
  )
);

-- Migration for a project that already ran the first version of this file.
alter table public.public_posts
  add column if not exists repost_of text references public.public_posts(id) on delete cascade;
alter table public.public_posts
  add column if not exists image_path text not null default '';
alter table public.public_posts
  alter column body set default '';
do $$ begin
  -- The original CHECK required 1..500; an image-only post needs 0 allowed.
  alter table public.public_posts drop constraint if exists public_posts_body_check;
  alter table public.public_posts
    add constraint public_posts_body_check check (char_length(body) <= 500);
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.public_posts add constraint public_posts_not_empty check (
    char_length(body) > 0 or image_path <> '' or repost_of is not null);
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.public_posts add constraint public_posts_reply_xor_repost
    check (reply_to is null or repost_of is null);
exception when duplicate_object then null; end $$;
alter table public.public_posts
  add column if not exists poll_options text[];
alter table public.public_posts
  add column if not exists poll_closes_at timestamptz;

create table if not exists public.public_post_likes (
  post_id     text not null references public.public_posts(id) on delete cascade,
  liker_phone text not null,
  created_at  timestamptz not null default now(),
  primary key (post_id, liker_phone)
);

-- One vote per person per poll — that is the primary key, not a rule the app
-- is trusted to keep. There is no UPDATE or DELETE granted below either: a
-- vote you can take back is a vote somebody can be talked into taking back,
-- and the tally would move under people who had already read it.
create table if not exists public.public_post_votes (
  post_id     text not null references public.public_posts(id) on delete cascade,
  voter_phone text not null,
  -- Zero-based index into the post's poll_options. Bounded statically here
  -- and against the actual number of answers in the insert policy.
  choice      int not null check (choice >= 0 and choice < 4),
  created_at  timestamptz not null default now(),
  primary key (post_id, voter_phone)
);

create index if not exists public_posts_recent_idx
  on public.public_posts (created_at desc);
create index if not exists public_posts_replies_idx
  on public.public_posts (reply_to, created_at);
create index if not exists public_posts_author_idx
  on public.public_posts (author_phone);
create index if not exists public_posts_reposts_idx
  on public.public_posts (repost_of);
create index if not exists public_posts_username_idx
  on public.public_posts (author_username, created_at desc);

alter table public.public_posts enable row level security;
alter table public.public_post_likes enable row level security;
alter table public.public_post_votes enable row level security;

-- ---------------------------------------------------------------------------
-- 2. Functions (the tables above have to exist first)
-- ---------------------------------------------------------------------------

-- Whether an account may write right now. A time-out silences without hiding:
-- existing posts stay up, no new ones land. A ban or suspension does both, via
-- is_locked_out in the read policy further down.
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

-- Counters that see past the like policy. Likes are readable only by the
-- person who made them, so a plain count() as the caller would return "1" for
-- your own like and 0 for everyone else's. These run as the owner precisely so
-- the totals are true without exposing who liked what.
create or replace function public.public_post_like_count(p text)
returns bigint
language sql
stable
security definer
set search_path = public
as $$
  select count(*) from public.public_post_likes where post_id = p;
$$;

create or replace function public.public_post_repost_count(p text)
returns bigint
language sql
stable
security definer
set search_path = public
as $$
  select count(*) from public.public_posts where repost_of = p;
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

-- The poll tally, one count per answer, in the answers' own order. Same reason
-- as the like counter: votes are readable only by the person who cast them, so
-- counting as the caller would report your own vote and nothing else. This
-- runs as the owner so the totals are true while who voted stays private.
create or replace function public.public_post_vote_counts(p text)
returns int[]
language sql
stable
security definer
set search_path = public
as $$
  select array(
    select (select count(*)::int
              from public.public_post_votes v
             where v.post_id = p and v.choice = i - 1)
      from generate_subscripts(
             coalesce((select poll_options from public.public_posts where id = p),
                      '{}'::text[]), 1) i
     order by i);
$$;

-- Whether a set of answers is one a poll may have. A CHECK cannot hold a
-- subquery, so the per-answer rules live in an immutable function it can call.
create or replace function public.poll_options_ok(opts text[])
returns boolean
language sql
immutable
as $$
  select opts is null or (
    array_length(opts, 1) between 2 and 4
    and not exists (
      select 1 from unnest(opts) o
       where char_length(btrim(o)) = 0 or char_length(o) > 40));
$$;

-- A poll is a top-level post with a question, two to four answers, and a
-- closing time. Anything else called a poll is a rendering bug.
do $$ begin
  alter table public.public_posts add constraint public_posts_poll_shape check (
    poll_options is null or (
      public.poll_options_ok(poll_options)
      and reply_to is null
      and repost_of is null
      and char_length(body) > 0
      and poll_closes_at is not null));
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- 3. Column privileges
-- ---------------------------------------------------------------------------
-- THE PHONE COLUMNS, PROPERLY.
--
-- `revoke select (author_phone) ...` on its own does nothing here, and that is
-- worth spelling out because it looks like it should work: Supabase grants
-- these roles table-wide SELECT on every new table in public, and Postgres
-- cannot carve a column out of a table-wide grant. The revoke succeeds, changes
-- nothing, and leaves every poster's phone number readable by anyone with the
-- app.
--
-- So the table-wide grant goes first, and the readable columns are handed back
-- one by one. Anything asking for `*` is refused outright.
revoke select on table public.public_posts from anon, authenticated;
grant select (id, author_username, author_name, author_verified, body,
              reply_to, repost_of, image_path, poll_options, poll_closes_at,
              created_at)
  on public.public_posts to anon, authenticated;

revoke select on table public.public_post_likes from anon, authenticated;
grant select (post_id, created_at)
  on public.public_post_likes to anon, authenticated;

-- Your own vote comes back so the app can show which answer you picked.
-- voter_phone is never granted, so the row is only ever yours to read — the
-- policy below sees to that as well.
revoke select on table public.public_post_votes from anon, authenticated;
grant select (post_id, choice, created_at)
  on public.public_post_votes to authenticated;

-- Writing is by whole row; the policies below decide whose row it may be.
grant insert, delete on public.public_posts to authenticated;
grant insert, delete on public.public_post_likes to authenticated;
-- Insert only. A vote is cast once and stands.
grant insert on public.public_post_votes to authenticated;

-- No UPDATE for anyone. There is no update policy either, but relying on that
-- alone makes an edit fail *silently* — an UPDATE matching no policy affects
-- zero rows without raising, which reads like success. Taking the privilege
-- away makes the refusal explicit.
revoke update on public.public_posts from anon, authenticated;
revoke update on public.public_post_likes from anon, authenticated;
revoke update, delete on public.public_post_votes from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Policies (the functions above have to exist first)
-- ---------------------------------------------------------------------------

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

-- You can see which posts YOU liked, and nobody else's. Who liked what is
-- nobody's business; the totals come from the counters above.
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

-- Same shape as likes: you can see your own vote, nobody else's, and the
-- tally comes from the counter that runs as the owner.
drop policy if exists public_post_votes_read_own on public.public_post_votes;
create policy public_post_votes_read_own on public.public_post_votes
  for select to authenticated
  using (voter_phone = (auth.jwt() ->> 'phone'));

-- Everything that makes a vote a vote is checked here rather than in the app.
-- A modified client gains nothing: it cannot vote as somebody else, cannot
-- pick an answer the poll does not have, cannot vote on a post that is not a
-- poll, and cannot vote after it closes. Voting twice is stopped by the
-- primary key above.
drop policy if exists public_post_votes_insert_own on public.public_post_votes;
create policy public_post_votes_insert_own on public.public_post_votes
  for insert to authenticated
  with check (
    voter_phone = (auth.jwt() ->> 'phone')
    and not public.is_silenced(voter_phone)
    and exists (
      select 1 from public.public_posts p
       where p.id = post_id
         and p.poll_options is not null
         and choice < coalesce(array_length(p.poll_options, 1), 0)
         and p.poll_closes_at > now()));

-- ---------------------------------------------------------------------------
-- 5. What clients actually read
-- ---------------------------------------------------------------------------
-- A view with no phone column in it at all, so the ordinary path cannot leak
-- one even by accident. security_invoker keeps the caller's RLS in force, which
-- is what hides a banned author's posts.
--
-- DROPPED FIRST, and it has to be. `create or replace view` may only append
-- columns to the end of an existing view; anything else is read as renaming
-- the columns that moved, and Postgres refuses:
--
--   42P16: cannot change name of view column "created_at" to "repost_of"
--
-- Which is exactly what happened to this file, because repost_of and
-- image_path belong next to the other post columns rather than tacked on after
-- the counters. Dropping is safe: no app reads this view through a stored
-- object, and the grant is re-issued below.
drop view if exists public.public_feed;
create or replace view public.public_feed
with (security_invoker = on) as
select
  p.id,
  p.author_username,
  p.author_name,
  p.author_verified,
  p.body,
  p.reply_to,
  p.repost_of,
  p.image_path,
  p.poll_options,
  p.poll_closes_at,
  p.created_at,
  public.public_post_like_count(p.id)   as like_count,
  public.public_post_reply_count(p.id)  as reply_count,
  public.public_post_repost_count(p.id) as repost_count,
  public.public_post_vote_counts(p.id)  as poll_votes
from public.public_posts p;

grant select on public.public_feed to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6. Images
-- ---------------------------------------------------------------------------
-- A public bucket, and public is the honest setting: these are attachments on
-- posts anyone can read, so sealing them the way listing videos are sealed
-- would accomplish nothing — the key would have to be as public as the post.
--
-- The object name is the post id, which is 8 random bytes, so a path is not
-- guessable from a username or a phone number.
insert into storage.buckets (id, name, public, file_size_limit)
values ('public-media', 'public-media', true, 4194304)
on conflict (id) do update
  set public = true,
      file_size_limit = 4194304;

-- Anyone may read (the bucket is public); only a signed-in account may add.
-- No update or delete for clients: an image swapped under a post that people
-- have already read is the same trick as editing the text.
drop policy if exists public_media_read on storage.objects;
create policy public_media_read on storage.objects
  for select to anon, authenticated
  using (bucket_id = 'public-media');

drop policy if exists public_media_insert on storage.objects;
create policy public_media_insert on storage.objects
  for insert to authenticated
  with check (bucket_id = 'public-media');
