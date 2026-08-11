-- The public forum: a world-readable, Reddit-shaped discussion board that lives
-- OUTSIDE any server. Anyone with the app can read it; anyone signed in can
-- post, comment and vote.
-- ============================================================================
-- Run ONCE in the Supabase SQL editor, AFTER docs/platform_moderation.sql and
-- docs/public_feed.sql — this leans on public.is_locked_out() (to keep banned
-- accounts out) and public.is_silenced() (to stop a timed-out account writing),
-- both defined by those files.
--
-- WHY THIS IS PLAINTEXT THE SERVER CAN READ, like the public feed.
--
-- Servers' forums are sealed under a community key; this one has no community,
-- so it has no key to seal under. A board whose audience is everyone cannot be
-- encrypted to everyone — the key would have to be public, which is the same as
-- no key. So the rule for these tables is the public feed's rule: **anything
-- posted here is public**, permanently, to anybody with the app. Private
-- messaging is untouched.
--
-- What is still protected is the author's phone number: clients are granted the
-- other columns and never that one, and attribution is by username (already
-- public in the directory), exactly as the public feed does it.
--
-- ORDER MATTERS, both directions: a function body is parsed at creation (its
-- tables must exist first), and a policy resolves the functions it calls at
-- creation (they must exist first). Hence tables, then functions, then
-- privileges and policies, then the view.

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------
create table if not exists public.public_forum_posts (
  -- Client-generated, so a device recognises its own post coming back.
  id              text primary key,
  -- E.164 digits. Ownership only — never granted to a client role below.
  author_phone    text not null,
  author_username text not null default '',
  author_name     text not null default '',
  -- Self-attested, like the badge on a chat message; the directory's own
  -- `verified` is the stronger claim. Here for rendering without a join.
  author_verified boolean not null default false,
  -- A forum post leads with a title, like Reddit. One to 140 characters.
  title           text not null check (char_length(title) between 1 and 140),
  -- The body may be empty when a GIF or image carries the post.
  body            text not null default '' check (char_length(body) <= 4000),
  -- One of the app's forumTags, or '' for untagged. Kept as a plain string so
  -- old rows stay valid if the tag list changes.
  tag             text not null default '',
  -- The section (subreddit-style board) this post lives in — a slug from
  -- public_forum_sections, or '' for the default "General" board. A plain
  -- string, not a foreign key, so a post survives its section being renamed
  -- or removed (it just falls back to General).
  section         text not null default '',
  -- An address, not bytes — a GIF picked from the provider is already served
  -- from their CDN; copying it here would be paying to serve it twice.
  gif_url         text not null default '',
  -- Object name in the world-readable public-media bucket (shared with the
  -- public feed). Unsealed, because a public post has nobody to keep it from.
  image_path      text not null default '',
  created_at      timestamptz not null default now(),
  -- Reserved for a later in-window edit path, like the public feed's; unused
  -- for now (there is no update grant or policy below, so posts are
  -- append-only until that lands).
  edited_at       timestamptz,
  -- Something has to be in a post: a title always is, so this only guards the
  -- degenerate all-blank row a bug could produce.
  constraint public_forum_posts_not_empty check (
    char_length(title) > 0
  )
);

create table if not exists public.public_forum_comments (
  id              text primary key,
  post_id         text not null
                    references public.public_forum_posts(id) on delete cascade,
  author_phone    text not null,
  author_username text not null default '',
  author_name     text not null default '',
  author_verified boolean not null default false,
  body            text not null default '' check (char_length(body) <= 4000),
  gif_url         text not null default '',
  -- A reply points at the comment it answers; deleting a comment takes its
  -- replies with it. Null for a top-level comment on the post.
  parent_id       text references public.public_forum_comments(id)
                    on delete cascade,
  created_at      timestamptz not null default now(),
  -- A comment with neither words nor a GIF is a rendering bug.
  constraint public_forum_comments_not_empty check (
    char_length(body) > 0 or gif_url <> ''
  )
);

-- One vote per person per post. Unlike a poll vote (which stands forever), a
-- forum vote TOGGLES: Reddit lets you change your mind or take it back, so
-- UPDATE and DELETE are granted on your own row below. dir is +1 or -1; the
-- score is their sum.
create table if not exists public.public_forum_votes (
  post_id     text not null
                references public.public_forum_posts(id) on delete cascade,
  voter_phone text not null,
  dir         smallint not null check (dir in (-1, 1)),
  created_at  timestamptz not null default now(),
  primary key (post_id, voter_phone)
);

create index if not exists public_forum_posts_recent_idx
  on public.public_forum_posts (created_at desc);
create index if not exists public_forum_posts_author_idx
  on public.public_forum_posts (author_phone);
create index if not exists public_forum_posts_tag_idx
  on public.public_forum_posts (tag, created_at desc);
create index if not exists public_forum_comments_post_idx
  on public.public_forum_comments (post_id, created_at);
create index if not exists public_forum_votes_post_idx
  on public.public_forum_votes (post_id);

-- Sections: the subreddit-style boards anyone signed in can create. The slug
-- is the id (lowercase, 2–24 of letters/digits/underscore); the title is what
-- shows. created_by_phone is ownership only, never granted to a client.
create table if not exists public.public_forum_sections (
  slug             text primary key check (slug ~ '^[a-z0-9_]{2,24}$'),
  title            text not null default '',
  description      text not null default '' check (char_length(description) <= 300),
  created_by_phone text not null,
  created_at       timestamptz not null default now()
);
create index if not exists public_forum_sections_recent_idx
  on public.public_forum_sections (created_at desc);

-- Migration for a project that already ran the first version of this file.
alter table public.public_forum_posts
  add column if not exists section text not null default '';
create index if not exists public_forum_posts_section_idx
  on public.public_forum_posts (section, created_at desc);

alter table public.public_forum_posts    enable row level security;
alter table public.public_forum_comments enable row level security;
alter table public.public_forum_votes    enable row level security;
alter table public.public_forum_sections enable row level security;

-- ---------------------------------------------------------------------------
-- 2. Functions (the tables above have to exist first)
-- ---------------------------------------------------------------------------

-- A post's score: the sum of its votes. SECURITY DEFINER because votes are
-- readable only by the person who cast them (the policy below), so counting as
-- the caller would report your own vote and nothing else. Running as the owner
-- makes the total true while who voted stays private — the same trick the
-- public feed's like/poll counters use.
create or replace function public.public_forum_score(p text)
returns bigint
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(dir), 0)::bigint
    from public.public_forum_votes where post_id = p;
$$;

-- How many comments a post has. Comments are world-readable, but count through
-- a definer function anyway so a banned author's comments (hidden by the read
-- policy) don't quietly change the number under different callers.
create or replace function public.public_forum_comment_count(p text)
returns bigint
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::bigint
    from public.public_forum_comments c
   where c.post_id = p
     and not public.is_locked_out(c.author_phone);
$$;

-- ---------------------------------------------------------------------------
-- 3. Column privileges
-- ---------------------------------------------------------------------------
-- THE PHONE COLUMN, PROPERLY — the same lesson as public_posts. Supabase grants
-- these roles table-wide SELECT on every new table in public, and Postgres
-- cannot carve a column out of a table-wide grant, so `revoke select
-- (author_phone)` on its own changes nothing and leaves every number readable.
-- Revoke the whole grant, then hand back the readable columns one by one.
revoke select on table public.public_forum_posts from anon, authenticated;
grant select (id, author_username, author_name, author_verified, title, body,
              tag, section, gif_url, image_path, created_at, edited_at)
  on public.public_forum_posts to anon, authenticated;

revoke select on table public.public_forum_comments from anon, authenticated;
grant select (id, post_id, author_username, author_name, author_verified,
              body, gif_url, parent_id, created_at)
  on public.public_forum_comments to anon, authenticated;

-- Your own vote comes back so the app can highlight the arrow you pressed.
--
-- voter_phone IS in this grant, and it has to be: the app changes a vote with
-- PostgreSQL's upsert, and `on conflict (post_id, voter_phone) do update`
-- requires SELECT on the columns of the conflict target. Withholding the
-- column made every DOWN-vote and every vote CHANGE fail with "permission
-- denied for table public_forum_votes" — the plain first upvote is an INSERT
-- and worked, which is why it looked like a moderation problem rather than a
-- grant one.
--
-- It costs no privacy. The read POLICY below is what keeps votes secret: it
-- scopes SELECT to `voter_phone = your own`, so the only number this column
-- can ever hand back is the one you already know. A column grant was never
-- what was protecting it.
revoke select on table public.public_forum_votes from anon, authenticated;
grant select (post_id, voter_phone, dir, created_at)
  on public.public_forum_votes to authenticated;

-- Sections are attributed to whoever made them by title only — created_by_phone
-- is ownership, never handed to a client.
revoke select on table public.public_forum_sections from anon, authenticated;
grant select (slug, title, description, created_at)
  on public.public_forum_sections to anon, authenticated;

-- Writing is by whole row; the policies decide whose row it may be.
grant insert, delete on public.public_forum_posts to authenticated;
grant insert, delete on public.public_forum_comments to authenticated;
-- A forum vote can be changed or taken back, unlike a poll vote.
grant insert, update, delete on public.public_forum_votes to authenticated;
-- Anyone signed in may create a section. No update/delete: a board people have
-- posted into is not one creator's to rename out from under them (a moderation
-- action can remove it server-side later).
grant insert on public.public_forum_sections to authenticated;
revoke update, delete on public.public_forum_sections from anon, authenticated;

-- No UPDATE on posts or comments for anyone, and no update policy either. An
-- UPDATE matching no policy affects zero rows *without raising*, which reads
-- like success; taking the privilege away makes the refusal explicit. (An
-- in-window edit path can be added later, like docs/public_feed_edit.sql.)
revoke update on public.public_forum_posts from anon, authenticated;
revoke update on public.public_forum_comments from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Policies (the functions above have to exist first)
-- ---------------------------------------------------------------------------

-- Readable by anyone with the app — except posts by an account that is banned
-- or suspended, which leave the board the moment the sanction lands.
drop policy if exists public_forum_posts_read on public.public_forum_posts;
create policy public_forum_posts_read on public.public_forum_posts
  for select to anon, authenticated
  using (not public.is_locked_out(author_phone));

-- You may only post as yourself, and only while you are allowed to. Both halves
-- are enforced here, so a modified client gains nothing: the phone comes from a
-- JWT it cannot forge, and a sanctioned account is refused.
drop policy if exists public_forum_posts_insert_own on public.public_forum_posts;
create policy public_forum_posts_insert_own on public.public_forum_posts
  for insert to authenticated
  with check (
    author_phone = (auth.jwt() ->> 'phone')
    and not public.is_silenced(author_phone)
  );

drop policy if exists public_forum_posts_delete_own on public.public_forum_posts;
create policy public_forum_posts_delete_own on public.public_forum_posts
  for delete to authenticated
  using (author_phone = (auth.jwt() ->> 'phone'));

-- Comments: same read rule (a banned author's comments vanish), same write
-- rule (only as yourself, only while allowed).
drop policy if exists public_forum_comments_read on public.public_forum_comments;
create policy public_forum_comments_read on public.public_forum_comments
  for select to anon, authenticated
  using (not public.is_locked_out(author_phone));

drop policy if exists public_forum_comments_insert_own
  on public.public_forum_comments;
create policy public_forum_comments_insert_own on public.public_forum_comments
  for insert to authenticated
  with check (
    author_phone = (auth.jwt() ->> 'phone')
    and not public.is_silenced(author_phone)
  );

drop policy if exists public_forum_comments_delete_own
  on public.public_forum_comments;
create policy public_forum_comments_delete_own on public.public_forum_comments
  for delete to authenticated
  using (author_phone = (auth.jwt() ->> 'phone'));

-- Votes: you can see only your own, cast/change/take back only your own, and
-- only while allowed to interact. Voting twice is stopped by the primary key;
-- changing your mind is an UPDATE of that one row.
drop policy if exists public_forum_votes_read_own on public.public_forum_votes;
create policy public_forum_votes_read_own on public.public_forum_votes
  for select to authenticated
  using (voter_phone = (auth.jwt() ->> 'phone'));

drop policy if exists public_forum_votes_insert_own on public.public_forum_votes;
create policy public_forum_votes_insert_own on public.public_forum_votes
  for insert to authenticated
  with check (
    voter_phone = (auth.jwt() ->> 'phone')
    and not public.is_silenced(voter_phone)
  );

drop policy if exists public_forum_votes_update_own on public.public_forum_votes;
create policy public_forum_votes_update_own on public.public_forum_votes
  for update to authenticated
  using (voter_phone = (auth.jwt() ->> 'phone'))
  with check (voter_phone = (auth.jwt() ->> 'phone'));

drop policy if exists public_forum_votes_delete_own on public.public_forum_votes;
create policy public_forum_votes_delete_own on public.public_forum_votes
  for delete to authenticated
  using (voter_phone = (auth.jwt() ->> 'phone'));

-- Sections: readable by anyone, created only as yourself while allowed to.
drop policy if exists public_forum_sections_read on public.public_forum_sections;
create policy public_forum_sections_read on public.public_forum_sections
  for select to anon, authenticated
  using (true);

drop policy if exists public_forum_sections_insert_own
  on public.public_forum_sections;
create policy public_forum_sections_insert_own on public.public_forum_sections
  for insert to authenticated
  with check (
    created_by_phone = (auth.jwt() ->> 'phone')
    and not public.is_silenced(created_by_phone)
  );

-- ---------------------------------------------------------------------------
-- 5. What clients actually read
-- ---------------------------------------------------------------------------
-- A view with no phone column in it at all, so the ordinary path cannot leak
-- one even by accident. security_invoker keeps the caller's RLS in force, which
-- is what hides a banned author's posts. Dropped first: create-or-replace may
-- only append columns to a view, and score/comment_count belong beside the post
-- columns, not tacked on after a later addition.
drop view if exists public.public_forum;
create view public.public_forum
with (security_invoker = on) as
select
  p.id,
  p.author_username,
  p.author_name,
  p.author_verified,
  p.title,
  p.body,
  p.tag,
  p.section,
  p.gif_url,
  p.image_path,
  p.created_at,
  p.edited_at,
  public.public_forum_score(p.id)         as score,
  public.public_forum_comment_count(p.id) as comment_count
from public.public_forum_posts p;

grant select on public.public_forum to anon, authenticated;
