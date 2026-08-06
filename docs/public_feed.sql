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
  -- An address, not bytes. A GIF picked from the provider is already served
  -- from their CDN; copying it here would be paying to store and serve a
  -- file somebody else already serves for free.
  gif_url       text not null default '',
  -- Object name in the same public-media bucket. Unsealed, unlike a server
  -- feed's video, because a public post is world-readable by definition —
  -- there is nobody to keep it from.
  video_path    text not null default '',
  -- A poll: two to four answers, with the question in `body`. Null for an
  -- ordinary post. Who voted for what is in public_post_votes and is readable
  -- by nobody; only the tally comes back, from the counter below.
  poll_options  text[],
  poll_closes_at timestamptz,
  created_at    timestamptz not null default now(),
  -- Something has to be in a post. Text, a picture, a GIF, a video, or a
  -- repost — an entirely empty row is a rendering bug waiting to happen.
  constraint public_posts_not_empty check (
    char_length(body) > 0 or image_path <> '' or gif_url <> ''
    or video_path <> '' or repost_of is not null
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

-- Media beyond a still photo.
--
-- gif_url is an ADDRESS, not bytes: a GIF picked from the provider already
-- lives on their CDN, and copying it into our bucket would be paying to
-- store and serve a file somebody else is already serving for free.
--
-- video_path is an object name in the same public-media bucket the images
-- use. Unsealed, unlike a server feed's video, because a public post is
-- world-readable by definition — there is nobody to keep it from, and a seal
-- whose key everybody holds is decoration.
alter table public.public_posts
  add column if not exists gif_url text not null default '';
alter table public.public_posts
  add column if not exists video_path text not null default '';
do $$ begin
  -- A post carrying only a GIF or only a video is a post. The original
  -- constraint predates both and would reject them as empty.
  alter table public.public_posts drop constraint if exists public_posts_not_empty;
  alter table public.public_posts add constraint public_posts_not_empty check (
    char_length(body) > 0 or image_path <> '' or gif_url <> ''
    or video_path <> '' or repost_of is not null);
exception when duplicate_object then null; end $$;

-- How many times a post was opened (2026-08-04). A COUNTER, not tracking:
-- no viewer identity is stored anywhere — there is no views table with a
-- phone in it, just a number on the post. Clients bump it through
-- public_post_viewed below (once per post per app run, by their own
-- discipline) and can never write it directly. Approximate by nature and
-- worth exactly what an X view count is worth.
alter table public.public_posts
  add column if not exists view_count bigint not null default 0;

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

-- Sparks: real-money tips pinned to a post. The MONEY moves person-to-person
-- over Stripe (payments-create-intent resolves the author server-side, so the
-- sparker never learns a phone number); this table is only the public tally.
-- Not keyed like likes on purpose — the same person may spark twice.
create table if not exists public.public_post_sparks (
  id            bigint generated always as identity primary key,
  post_id       text not null references public.public_posts(id) on delete cascade,
  sparker_phone text not null,
  cents         int not null check (cents > 0 and cents <= 50000),
  created_at    timestamptz not null default now()
);
create index if not exists public_post_sparks_post_idx
  on public.public_post_sparks (post_id);

alter table public.public_posts enable row level security;
alter table public.public_post_likes enable row level security;
alter table public.public_post_votes enable row level security;
alter table public.public_post_sparks enable row level security;

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

-- Spark tallies, same shape as the like counter: rows are readable only by
-- the person who sparked, so counting as the caller would report your own
-- sparks and nothing else. The totals are true while who sparked stays
-- private.
create or replace function public.public_post_spark_count(p text)
returns bigint
language sql
stable
security definer
set search_path = public
as $$
  select count(*) from public.public_post_sparks where post_id = p;
$$;

-- Whether [digitsv] wrote post [p]. SECURITY DEFINER because the spark
-- policy needs the answer and the caller is (rightly) not allowed to read
-- author_phone — a plain subquery in the policy dies on the column grant.
create or replace function public.is_post_author(p text, digitsv text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.public_posts
     where id = p and author_phone = digitsv);
$$;

create or replace function public.public_post_spark_cents(p text)
returns bigint
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(cents), 0) from public.public_post_sparks where post_id = p;
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
-- gif_url and video_path belong on this list, not merely in the table. A
-- column added without being granted here is a column the app cannot read —
-- the post comes back with its video silently missing and nothing says why.
grant select (id, author_username, author_name, author_verified, body,
              reply_to, repost_of, image_path, gif_url, video_path,
              poll_options, poll_closes_at, created_at, view_count)
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

-- Your own sparks come back so the app can show the amber bolt; who else
-- sparked is nobody's business — totals come from the counters.
revoke select on table public.public_post_sparks from anon, authenticated;
grant select (post_id, cents, created_at)
  on public.public_post_sparks to authenticated;

-- Writing is by whole row; the policies below decide whose row it may be.
grant insert, delete on public.public_posts to authenticated;
grant insert, delete on public.public_post_likes to authenticated;
-- Insert only. A vote is cast once and stands.
grant insert on public.public_post_votes to authenticated;
-- Insert only, likewise: a spark is money that moved — it does not un-move.
grant insert on public.public_post_sparks to authenticated;

-- No UPDATE for anyone. There is no update policy either, but relying on that
-- alone makes an edit fail *silently* — an UPDATE matching no policy affects
-- zero rows without raising, which reads like success. Taking the privilege
-- away makes the refusal explicit.
revoke update on public.public_posts from anon, authenticated;
revoke update on public.public_post_likes from anon, authenticated;
revoke update, delete on public.public_post_votes from anon, authenticated;
revoke update, delete on public.public_post_sparks from anon, authenticated;

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

-- Sparks: you may record only your own, only while allowed to interact, and
-- never on your own post — self-sparking is a fake tally with your own money.
drop policy if exists public_post_sparks_read_own on public.public_post_sparks;
create policy public_post_sparks_read_own on public.public_post_sparks
  for select to authenticated
  using (sparker_phone = (auth.jwt() ->> 'phone'));

drop policy if exists public_post_sparks_insert_own on public.public_post_sparks;
create policy public_post_sparks_insert_own on public.public_post_sparks
  for insert to authenticated
  with check (
    sparker_phone = (auth.jwt() ->> 'phone')
    and not public.is_silenced(sparker_phone)
    -- The FK guarantees the post exists; the definer function answers the
    -- one question the caller may not ask directly.
    and not public.is_post_author(post_id, sparker_phone));

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
  p.gif_url,
  p.video_path,
  p.poll_options,
  p.poll_closes_at,
  p.created_at,
  p.view_count,
  public.public_post_like_count(p.id)   as like_count,
  public.public_post_reply_count(p.id)  as reply_count,
  public.public_post_repost_count(p.id) as repost_count,
  public.public_post_vote_counts(p.id)  as poll_votes,
  public.public_post_spark_count(p.id)  as spark_count,
  public.public_post_spark_cents(p.id)  as spark_cents
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

-- ---------------------------------------------------------------------------
-- Who liked a post (2026-08-04). The likes table stores the liker's PHONE
-- and its policy hides every row but your own — that stays exactly as it
-- is. This function is the one window: it joins to the directory and
-- answers USERNAMES only, so "who liked" is as public as a like on a
-- public post while a phone number still never leaves the table. Likers
-- with no directory row — or a hidden (deactivated) one — are simply not
-- listed, so the like count can honestly exceed the names shown.
-- (Reposts need nothing here: a repost is an ordinary public post whose
-- repost_of points at the original, readable like any other.)

-- Order-independent with docs/account_lifecycle.sql, which also adds this.
alter table public.usernames
  add column if not exists hidden boolean not null default false;

create or replace function public.public_post_likers(p text)
returns table(username text, name text)
language sql
stable
security definer
set search_path = public
as $$
  select u.username, coalesce(u.name, '')
    from public.public_post_likes l
    join public.usernames u on u.phone = l.liker_phone
   where l.post_id = p
     and not coalesce(u.hidden, false)
   order by l.created_at desc
   limit 100;
$$;

grant execute on function public.public_post_likers(text) to anon, authenticated;

-- Counts one view. The table grants clients no UPDATE, so this definer
-- function is the only door, and all it can do is add one.
create or replace function public.public_post_viewed(p text)
returns void
language sql
volatile
security definer
set search_path = public
as $$
  update public.public_posts set view_count = view_count + 1 where id = p;
$$;

grant execute on function public.public_post_viewed(text) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6. Follows — the one social-graph table (2026-08-05, the owner's call:
--    follower and following counts should be real for everybody).
--
-- Same privacy shape as likes: phones inside, usernames out. Both ends of
-- an edge are stored by PHONE — the follower's vouched for by the JWT, the
-- followed resolved from their handle at follow time INSIDE a definer
-- function, so a later username change never orphans the edge and the
-- handle→phone mapping never crosses the wire. There are NO direct grants
-- on the table at all: the functions below are the only doors, and none of
-- them ever returns a phone number.
-- ---------------------------------------------------------------------------

create table if not exists public.public_follows (
  follower_phone text not null,
  followed_phone text not null,
  created_at     timestamptz not null default now(),
  primary key (follower_phone, followed_phone)
);

alter table public.public_follows enable row level security;
revoke all on table public.public_follows from anon, authenticated;

-- Follow by handle. Idempotent; a self-follow or an unknown handle is a
-- silent no-op — the client treats the server graph as best-effort beside
-- its local list, so there is nothing useful to throw at it.
-- Both edges are keyed by the phone format the username directory stores
-- (E.164, with the leading '+'). The JWT's `phone` claim, though, arrives
-- WITHOUT the '+', so writing it raw made `follower_phone` a value that could
-- never join back to `usernames.phone` — the follower's own row — and the
-- FOLLOWING count silently stayed 0 for everyone. So resolve the caller to
-- their directory phone first (compare on digits only), and store THAT.
create or replace function public.public_follow(u text)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  jwt_phone text := (auth.jwt() ->> 'phone');
  me   text;
  them text;
begin
  if jwt_phone is null or jwt_phone = '' then return; end if;
  select phone into me from public.usernames
   where regexp_replace(phone, '\D', '', 'g')
       = regexp_replace(jwt_phone, '\D', '', 'g')
   limit 1;
  if me is null then return; end if;
  select phone into them from public.usernames
   where lower(username) = lower(u) limit 1;
  if them is null or them = me then return; end if;
  insert into public.public_follows (follower_phone, followed_phone)
  values (me, them)
  on conflict do nothing;
end;
$$;

create or replace function public.public_unfollow(u text)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  jwt_phone text := (auth.jwt() ->> 'phone');
  me   text;
  them text;
begin
  if jwt_phone is null or jwt_phone = '' then return; end if;
  select phone into me from public.usernames
   where regexp_replace(phone, '\D', '', 'g')
       = regexp_replace(jwt_phone, '\D', '', 'g')
   limit 1;
  if me is null then return; end if;
  select phone into them from public.usernames
   where lower(username) = lower(u) limit 1;
  if them is null then return; end if;
  delete from public.public_follows
   where follower_phone = me and followed_phone = them;
end;
$$;

-- Both numbers in one round trip, for the profile header.
create or replace function public.public_follow_counts(u text)
returns table(followers bigint, following bigint)
language sql
stable
security definer
set search_path = public
as $$
  select
    (select count(*)
       from public.public_follows f
       join public.usernames t on t.phone = f.followed_phone
      where lower(t.username) = lower(u)),
    (select count(*)
       from public.public_follows f
       join public.usernames s on s.phone = f.follower_phone
      where lower(s.username) = lower(u));
$$;

-- Who follows them / who they follow — usernames only, hidden accounts
-- filtered, bounded like the likers window.
create or replace function public.public_followers(u text)
returns table(username text, name text)
language sql
stable
security definer
set search_path = public
as $$
  select s.username, coalesce(s.name, '')
    from public.public_follows f
    join public.usernames t on t.phone = f.followed_phone
    join public.usernames s on s.phone = f.follower_phone
   where lower(t.username) = lower(u)
     and not coalesce(s.hidden, false)
   order by f.created_at desc
   limit 100;
$$;

create or replace function public.public_following(u text)
returns table(username text, name text)
language sql
stable
security definer
set search_path = public
as $$
  select t.username, coalesce(t.name, '')
    from public.public_follows f
    join public.usernames s on s.phone = f.follower_phone
    join public.usernames t on t.phone = f.followed_phone
   where lower(s.username) = lower(u)
     and not coalesce(t.hidden, false)
   order by f.created_at desc
   limit 100;
$$;

grant execute on function public.public_follow(text) to authenticated;
grant execute on function public.public_unfollow(text) to authenticated;
grant execute on function public.public_follow_counts(text) to anon, authenticated;
grant execute on function public.public_followers(text) to anon, authenticated;
grant execute on function public.public_following(text) to anon, authenticated;
