-- ============================================================================
-- OkayMessenger — run-all SQL bundle
-- Generated from the individual docs/*.sql files in dependency order (the same
-- order tool/check_sql.sh applies and verifies). Paste this whole file ONCE
-- into the Supabase SQL editor and run it. Every statement is idempotent
-- (create-or-replace / if-not-exists / drop-if-exists), so re-running is safe.
--
-- Assumes supabase/schema.sql (the base schema) is already applied to the
-- project. Storage BUCKETS still need creating in the dashboard where noted
-- (chat-backups, market-media, voice-notes, public-media) — the policy SQL for
-- them is included, but the bucket itself is a dashboard/Storage step.
-- ============================================================================


-- ####################################################################
-- ## docs/platform_moderation.sql
-- ####################################################################
-- App-wide roles, sanctions, and reports.
-- ============================================================================
-- Run ONCE in the Supabase SQL editor. Then grant yourself the owner role with
-- the statement at the very bottom (replace the number with your own).
--
-- WHAT THIS CAN DO. A sanction removes an account from the *shared*
-- infrastructure: the directory it is found through, claiming a username, push
-- notifications, payments. Postgres enforces the directory part through row
-- level security, so it holds against any client, modified or not.
--
-- WHAT IT CANNOT DO, BY DESIGN. It cannot read, remove, or moderate anybody's
-- messages. Message bodies are end-to-end encrypted before they leave the
-- device and the server only ever holds sealed envelopes it has no key for.
-- There is no server-side copy of a conversation to act on, and adding one
-- would break the promise the whole app rests on. Moderation here is about
-- access to the platform, not about content in private chats.

-- ---------------------------------------------------------------------------
-- Who holds power
-- ---------------------------------------------------------------------------
-- Service-role only: RLS is on and there is no client policy, so no app build
-- can read or write this table. A role the client could grant itself would be
-- worth nothing, so roles are granted here, by SQL, by whoever owns the
-- project.
create table if not exists public.platform_roles (
  phone      text primary key,              -- E.164 digits
  role       text not null check (role in ('owner', 'admin', 'moderator')),
  granted_by text not null default '',
  created_at timestamptz not null default now()
);
alter table public.platform_roles enable row level security;

-- ---------------------------------------------------------------------------
-- What has been done to an account
-- ---------------------------------------------------------------------------
-- One row per sanctioned account. Written only by the moderation-act Edge
-- Function (service role), which checks the caller's role first. `until` null
-- means permanent, which only a ban is.
create table if not exists public.account_sanctions (
  phone       text primary key,             -- E.164 digits
  kind        text not null check (kind in ('timeout', 'suspend', 'ban')),
  reason      text not null default '' check (char_length(reason) <= 500),
  until       timestamptz,
  actor_phone text not null default '',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
alter table public.account_sanctions enable row level security;

-- Read-only to the app so a sanctioned device can be told why it is locked
-- out (and so every device agrees who is hidden). Nothing here is private:
-- it is a list of accounts that may not use the app.
drop policy if exists account_sanctions_read on public.account_sanctions;
create policy account_sanctions_read on public.account_sanctions
  for select to anon, authenticated using (true);
-- No insert/update/delete policy: only the service role changes a sanction.

create index if not exists account_sanctions_until_idx
  on public.account_sanctions (until);

-- Every sanction and lift, kept even after the sanction goes away. Moderation
-- without a record of who did what is just power.
create table if not exists public.moderation_log (
  id           bigint generated always as identity primary key,
  created_at   timestamptz not null default now(),
  actor_phone  text not null default '',
  actor_role   text not null default '',
  target_phone text not null default '',
  action       text not null default '',
  reason       text not null default '',
  until        timestamptz
);
alter table public.moderation_log enable row level security;

-- ---------------------------------------------------------------------------
-- Reports from people using the app
-- ---------------------------------------------------------------------------
-- "Report" used to be honest about going nowhere: it hid a listing locally and
-- said so, because there was no central moderator. Now there is one, and this
-- is where a report lands. A report carries what was reported and why — never
-- message content, which the reporter's device holds and the server cannot
-- read anyway.
create table if not exists public.moderation_reports (
  id             bigint generated always as identity primary key,
  created_at     timestamptz not null default now(),
  target_phone   text not null default '',
  target_handle  text not null default '',
  reporter_phone text not null default '',
  reason         text not null default '',
  detail         text not null default '' check (char_length(detail) <= 1000),
  context        text not null default '',   -- 'listing', 'post', 'chat', …
  handled        boolean not null default false
);
alter table public.moderation_reports enable row level security;

-- Anyone with the app may file one, and only about themselves as reporter.
-- Reports are not readable by clients — one person's report is nobody else's
-- business; moderators read them through the Edge Function.
drop policy if exists moderation_reports_insert on public.moderation_reports;
create policy moderation_reports_insert on public.moderation_reports
  for insert to anon, authenticated with check (true);

create index if not exists moderation_reports_open_idx
  on public.moderation_reports (handled, created_at desc);

-- ---------------------------------------------------------------------------
-- THE ENFORCEMENT: banned and suspended accounts leave the directory
-- ---------------------------------------------------------------------------
-- This is the part that is real regardless of what any app build does, because
-- Postgres applies it to every query. A hidden account cannot be found by
-- username search or by contact sync, and cannot claim or change a username.
--
-- A time-out is deliberately NOT hidden: it silences, it does not disappear
-- someone mid-conversation.
create or replace function public.is_locked_out(p text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.account_sanctions s
     where s.phone = p
       and s.kind in ('ban', 'suspend')
       and (s.until is null or s.until > now())
  );
$$;

-- Reading the directory: locked-out rows are invisible. Your own row stays
-- visible to you, so a suspended account can still see its own profile and be
-- told what happened instead of appearing to have been deleted.
drop policy if exists usernames_read on public.usernames;
create policy usernames_read on public.usernames
  for select to authenticated
  using (
    phone = (auth.jwt() ->> 'phone')
    or not public.is_locked_out(phone)
  );

-- Claiming or changing a username: locked out means locked out.
drop policy if exists usernames_insert_own on public.usernames;
create policy usernames_insert_own on public.usernames
  for insert to authenticated
  with check (
    phone = (auth.jwt() ->> 'phone')
    and not public.is_locked_out(phone)
  );

drop policy if exists usernames_update_own on public.usernames;
create policy usernames_update_own on public.usernames
  for update to authenticated
  using (phone = (auth.jwt() ->> 'phone'))
  with check (
    phone = (auth.jwt() ->> 'phone')
    and not public.is_locked_out(phone)
  );

-- Push tokens too: a locked-out account stops receiving notifications at the
-- source rather than being quietly delivered to.
drop policy if exists push_tokens_upsert_own on public.push_tokens;
create policy push_tokens_upsert_own on public.push_tokens
  for insert to authenticated
  with check (
    phone = (auth.jwt() ->> 'phone')
    and not public.is_locked_out(phone)
  );

-- ---------------------------------------------------------------------------
-- Housekeeping
-- ---------------------------------------------------------------------------
-- Lapsed sanctions stop applying the moment their clock runs out (the checks
-- above are all time-aware), so sweeping is tidiness rather than enforcement.
-- Call it from a scheduled job if you want the table to stay small.
create or replace function public.sweep_expired_sanctions()
returns integer
language plpgsql
as $$
declare removed integer;
begin
  delete from public.account_sanctions
   where until is not null and until <= now();
  get diagnostics removed = row_count;
  return removed;
end;
$$;

-- ---------------------------------------------------------------------------
-- GRANT YOURSELF THE OWNER ROLE — edit the number, then run this line.
-- ---------------------------------------------------------------------------
-- insert into public.platform_roles (phone, role, granted_by)
-- values ('15551234567', 'owner', 'bootstrap')
-- on conflict (phone) do update set role = 'owner';


-- ####################################################################
-- ## docs/public_feed.sql
-- ####################################################################
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

-- Who has viewed a post (2026-08-07). Unlike the old anonymous view_count,
-- this holds one row per (post, viewer), so the same reader re-opening a post
-- can never inflate its count, and the author can be shown WHO looked. The
-- primary key IS the dedupe. viewer_phone is never granted to a client (below);
-- the count comes off the denormalised public_posts.view_count, kept in step by
-- public_post_viewed, and the author's "viewed by" list comes from the
-- public_post_viewers window — a client can never read this table directly.
create table if not exists public.public_post_views (
  post_id      text not null references public.public_posts(id) on delete cascade,
  viewer_phone text not null,
  created_at   timestamptz not null default now(),
  primary key (post_id, viewer_phone)
);
create index if not exists public_post_views_post_idx
  on public.public_post_views (post_id, created_at desc);

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
alter table public.public_post_views enable row level security;
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

-- The views table is never client-readable in any column: who viewed a post is
-- the author's to see, and only through the public_post_viewers window below.
-- No insert/delete/update grant either — the only writer is the security-
-- definer public_post_viewed, which runs as the table owner past this.
revoke select on table public.public_post_views from anon, authenticated;
revoke insert, update, delete on public.public_post_views from anon, authenticated;

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

-- Counts one view — ONCE per viewer, forever. The (post, viewer) primary key
-- on public_post_views is the dedupe: a reader re-opening a post inserts
-- nothing the second time, so view_count only moves on a genuinely new viewer.
-- An anonymous reader (numberless account on the anon key, no jwt phone) is not
-- counted and not listed — a view you can't attribute can't be deduped or shown
-- either. The table grants clients nothing, so this definer function is the
-- only writer.
create or replace function public.public_post_viewed(p text)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  ph text := nullif(auth.jwt() ->> 'phone', '');
begin
  if ph is null then
    return;
  end if;
  insert into public.public_post_views (post_id, viewer_phone)
    values (p, ph)
    on conflict (post_id, viewer_phone) do nothing;
  if found then
    update public.public_posts set view_count = view_count + 1 where id = p;
  end if;
end;
$$;

grant execute on function public.public_post_viewed(text) to anon, authenticated;

-- Who viewed a post — the SAME directory-join window as public_post_likers,
-- newest first. Only ever reached by the post's author from the app (the UI
-- shows the "viewed by" list on your own posts), but the window itself carries
-- no phones and hides accounts that asked to be hidden, like every other.
create or replace function public.public_post_viewers(p text)
returns table(username text, name text)
language sql
stable
security definer
set search_path = public
as $$
  select u.username, coalesce(u.name, '')
    from public.public_post_views v
    join public.usernames u on u.phone = v.viewer_phone
   where v.post_id = p
     and not coalesce(u.hidden, false)
   order by v.created_at desc
   limit 100;
$$;

grant execute on function public.public_post_viewers(text) to anon, authenticated;

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


-- ####################################################################
-- ## docs/creator_subscriptions.sql
-- ####################################################################
-- Creator subscriptions (2026-08-05): a creator may publish subscribers-only
-- posts to the public feed, and a reader pays a monthly pass to read them.
--
-- WHY ACCESS-CONTROL, NOT END-TO-END SEALING. The public feed is world-readable
-- and SERVER-MODERATED (every post's text is screened). A paid post is therefore
-- gated by ACCESS, not sealed: a sealed body could never be screened, and
-- unscreenable pay-walled content is exactly the abuse vector that has burned
-- other creator platforms. True sealing is reserved for paid SERVERS, whose feed
-- is already private by design. So the public row carries only a teaser; the
-- real text lives in `public_paid_bodies`, which NOTHING may select directly —
-- `public_paid_body()` is the one door, and it opens only for the author or an
-- account holding an active pass.
--
-- WHY THE CLIENT CANNOT GRANT ITSELF A PASS. The entitlement in
-- `creator_subscriptions` is written ONLY by the `creator-subscribe` Edge
-- Function, which verifies the App Store receipt first (the same trust model as
-- the storage subscription). There are no client-facing writes on that table.
--
-- Idempotent: safe to run more than once. Apply after docs/public_feed.sql
-- (it extends public_posts and the public_feed view, both defined there).

-- ---------------------------------------------------------------------------
-- 1. Post columns: whether it's a paid post, and the monthly price.
-- ---------------------------------------------------------------------------
-- sub_cents is denormalised onto the row so the locked card can show a price
-- to a stranger who holds no profile for the creator.
alter table public.public_posts
  add column if not exists paid boolean not null default false;
alter table public.public_posts
  add column if not exists sub_cents int not null default 0;

-- The feed view reads by COLUMN grant (author_phone is deliberately withheld),
-- so a new column the view returns has to be granted here too, or it reads back
-- null with nothing to say why.
grant select (paid, sub_cents) on public.public_posts to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. The feed view, now carrying paid + sub_cents.
-- ---------------------------------------------------------------------------
-- The `body` it returns is already the public teaser for a paid post — the
-- composer writes only the teaser to public_posts.body and the real text to
-- public_paid_bodies below — so the private text never enters this view.
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
  public.public_post_spark_cents(p.id)  as spark_cents,
  p.paid,
  p.sub_cents
from public.public_posts p;

grant select on public.public_feed to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. The paid bodies — the private text, readable by nobody directly.
-- ---------------------------------------------------------------------------
create table if not exists public.public_paid_bodies (
  post_id      text primary key
                 references public.public_posts(id) on delete cascade,
  author_phone text not null,
  body         text not null,
  created_at   timestamptz not null default now()
);

alter table public.public_paid_bodies enable row level security;

-- Take back the table-wide SELECT Supabase grants every new public table: the
-- whole point of this table is that its body is never world-readable. The
-- security-definer reader below bypasses this; a direct `select body` does not.
revoke select on table public.public_paid_bodies from anon, authenticated;
-- No update or delete for anyone — a paid body swapped under readers who
-- already paid is the same trick as editing a public post after the fact.
revoke update, delete on table public.public_paid_bodies from anon, authenticated;
grant insert on public.public_paid_bodies to authenticated;

-- A creator inserts only their OWN row, vouched by the JWT phone.
drop policy if exists paid_bodies_insert on public.public_paid_bodies;
create policy paid_bodies_insert on public.public_paid_bodies
  for insert to authenticated
  with check (author_phone = (auth.jwt() ->> 'phone'));

-- ---------------------------------------------------------------------------
-- 4. The passes. Both ends by phone (like follows); NO client grants at all —
--    the entitlement is written only by the receipt-verifying edge function
--    (service role, which bypasses RLS), and read only through the functions
--    below. last_txn_id dedupes a receipt so one purchase grants one month.
-- ---------------------------------------------------------------------------
create table if not exists public.creator_subscriptions (
  subscriber_phone text not null,
  creator_phone    text not null,
  expires_at       timestamptz not null,
  product_id       text not null default '',
  last_txn_id      text not null default '',
  updated_at       timestamptz not null default now(),
  primary key (subscriber_phone, creator_phone)
);

alter table public.creator_subscriptions enable row level security;
revoke all on table public.creator_subscriptions from anon, authenticated;

-- One row per consumed receipt, so the same signed transaction can't be
-- replayed to buy a month of a dozen different creators.
create table if not exists public.creator_sub_receipts (
  txn_id     text primary key,
  created_at timestamptz not null default now()
);
alter table public.creator_sub_receipts enable row level security;
revoke all on table public.creator_sub_receipts from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. Read gates (security definer — the only doors).
-- ---------------------------------------------------------------------------

-- The one door to a paid body: the author, or an account with an active pass.
-- Anyone else (or anon, which has no phone) gets null.
create or replace function public.public_paid_body(p text)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  me     text := (auth.jwt() ->> 'phone');
  author text;
  txt    text;
begin
  select author_phone, body into author, txt
    from public.public_paid_bodies where post_id = p;
  if author is null then return null; end if;
  if me is not null and me = author then return txt; end if;
  if me is null then return null; end if;
  if exists (
    select 1 from public.creator_subscriptions s
     where s.subscriber_phone = me
       and s.creator_phone = author
       and s.expires_at > now()
  ) then
    return txt;
  end if;
  return null;
end;
$$;

-- Whether the caller holds an active pass to a creator (by handle).
create or replace function public.creator_sub_active(u text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
      from public.creator_subscriptions s
      join public.usernames t on t.phone = s.creator_phone
     where s.subscriber_phone = (auth.jwt() ->> 'phone')
       and lower(t.username) = lower(u)
       and s.expires_at > now()
  );
$$;

-- The caller's own active passes — creator handle + expiry — for reconciling
-- the local list on start. Only ever your own rows; no phone ever returned.
create or replace function public.creator_my_subs()
returns table(creator text, expires_at timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  select t.username, s.expires_at
    from public.creator_subscriptions s
    join public.usernames t on t.phone = s.creator_phone
   where s.subscriber_phone = (auth.jwt() ->> 'phone')
     and s.expires_at > now();
$$;

-- How many active subscribers a creator has, for their own dashboard. A count
-- only — who is subscribed is nobody's business but the counter's.
create or replace function public.creator_subscribers_count(u text)
returns bigint
language sql
stable
security definer
set search_path = public
as $$
  select count(*)
    from public.creator_subscriptions s
    join public.usernames t on t.phone = s.creator_phone
   where lower(t.username) = lower(u)
     and s.expires_at > now();
$$;

grant execute on function public.public_paid_body(text) to anon, authenticated;
grant execute on function public.creator_sub_active(text) to authenticated;
grant execute on function public.creator_my_subs() to authenticated;
grant execute on function public.creator_subscribers_count(text)
  to anon, authenticated;


-- ####################################################################
-- ## docs/payment_controls.sql
-- ####################################################################
-- Who may send you money, how much can leave at once, and how much in a day.
-- ============================================================================
-- Run this in the Supabase dashboard (SQL Editor -> New query -> Run). Safe to
-- run again: a project already holding the first version is upgraded in place.
--
-- Every one of these is enforced in payments-create-intent, before a charge
-- exists. A limit the app applies is a limit a modified app ignores.

create table if not exists public.payment_settings (
  phone text primary key,                    -- E.164 digits

  -- Who is allowed to send money to this person.
  --   anyone  - the default
  --   nobody  - receiving is switched off entirely
  accepts_from text not null default 'anyone'
    check (accepts_from in ('anyone', 'nobody')),

  -- The most this account may SEND in a rolling 24 hours, in cents. Caps the
  -- damage from a phone someone else has picked up, and from a mistake made
  -- repeatedly. Null means the project default applies.
  daily_send_limit_cents int,

  -- The most one single transfer may be, in cents. A day's worth of small
  -- mistakes and one big one are different failures; the rolling cap only
  -- catches the first. Null or 0 means no per-transfer cap.
  max_send_cents int,

  -- Everything off, both directions, in one tap. Nothing leaves and nothing
  -- arrives while this is set.
  paused boolean not null default false,

  -- A raise that has been asked for and has not arrived yet. Lowering a limit
  -- takes effect immediately; raising one waits 24 hours, so an unlocked phone
  -- in the wrong hands is held to whatever its owner chose while calm. Both
  -- columns of a pair are set together or not at all.
  pending_daily_send_limit_cents int,
  pending_daily_effective_at timestamptz,
  pending_max_send_cents int,
  pending_max_effective_at timestamptz,

  updated_at timestamptz not null default now()
);

-- Added after the first version shipped. The columns are in the CREATE above
-- too, so a fresh project reads the whole table in one place; these ALTERs are
-- what upgrade a project that already ran v1. Both are no-ops on the other.
alter table public.payment_settings
  add column if not exists paused boolean not null default false;
alter table public.payment_settings
  add column if not exists max_send_cents int;
alter table public.payment_settings
  add column if not exists pending_daily_send_limit_cents int;
alter table public.payment_settings
  add column if not exists pending_daily_effective_at timestamptz;
alter table public.payment_settings
  add column if not exists pending_max_send_cents int;
alter table public.payment_settings
  add column if not exists pending_max_effective_at timestamptz;

-- People this account refuses money from, whatever accepts_from says.
create table if not exists public.payment_blocks (
  phone         text not null,   -- the recipient doing the blocking
  blocked_phone text not null,   -- the sender being refused
  created_at    timestamptz not null default now(),
  primary key (phone, blocked_phone)
);

-- Only the Edge Functions touch either table, via the service-role key, which
-- bypasses RLS. Enabling RLS with no policies means a client holding the
-- publishable key cannot raise its own send limit or unblock itself.
alter table public.payment_settings enable row level security;
alter table public.payment_blocks enable row level security;

drop policy if exists payment_settings_all on public.payment_settings;
drop policy if exists payment_blocks_all on public.payment_blocks;

-- The rolling-window sum the send limit is checked against. Only completed
-- and in-flight charges count; blocked and failed ones never took money.
create index if not exists payment_transactions_from_created_idx
  on public.payment_transactions (from_phone, updated_at);

-- What a transfer said it was for, so the history can show it (and mark
-- sparks). The note was always plaintext payment data — it already rides the
-- Stripe intent's metadata — so storing it here exposes nothing new. The
-- table stays RLS-locked; payments-history is still the only way to read it.
alter table public.payment_transactions
  add column if not exists note text not null default '';

-- ---------------------------------------------------------------------------
-- Debit-card attach history — the record behind two safeguards: a newly
-- attached card waits seven business days before instant payouts (an account
-- takeover attaches its own card and drains the balance in one motion; the
-- wait gives the real owner time to notice), and a third card inside thirty
-- days locks the feature until the changes age out. SERVICE ROLE ONLY: the
-- Edge Functions write and read it, clients get nothing — a row a client
-- could delete is a waiting period a thief could skip.
-- ---------------------------------------------------------------------------
create table if not exists public.payment_card_events (
  id         bigint generated always as identity primary key,
  phone      text not null,
  created_at timestamptz not null default now()
);
-- Bank (direct deposit) changes share the ledger: same safeguards, same
-- reasons — swapping where the money lands is the other half of the drain.
alter table public.payment_card_events
  add column if not exists kind text not null default 'card';
create index if not exists payment_card_events_phone_idx
  on public.payment_card_events (phone, created_at desc);
alter table public.payment_card_events enable row level security;
revoke all on table public.payment_card_events from anon, authenticated;


-- ####################################################################
-- ## docs/directory_numberless.sql
-- ####################################################################
-- Username search and directory rows for accounts with no phone number.
-- ============================================================================
-- Run ONCE in the Supabase SQL editor, AFTER docs/platform_moderation.sql
-- (the search filter reuses its is_locked_out()).
--
-- WHY. A numberless account has no Supabase session at all — Supabase
-- authenticates a phone — and the directory's RLS speaks only to
-- `authenticated`. So such an account could neither claim its @handle nor
-- search anyone else's, and the handle is the ONE thing a numberless account
-- can be found by. Two SECURITY DEFINER functions open exactly that path and
-- nothing more:
--
--   find_people(q)      what an authenticated directory search already shows
--                       (opted-in, not-locked-out rows), now answerable with
--                       the anon key. The raw table stays unreadable to anon.
--   claim_numberless()  inserts a directory row for an ACCOUNT CODE only —
--                       12 digits with a leading 00, a shape no real E.164
--                       number can have — so a phone account's row still
--                       requires the verified session that owns it. First
--                       claim wins: with no session there is no way to prove
--                       a code is yours, so an existing row's handle can
--                       never be changed through here (only its display name,
--                       and only when the handle matches).

-- The columns the functions read, for projects that have not run
-- docs/directory_privacy.sql / docs/identity_directory_badge.sql yet.
alter table public.usernames
  add column if not exists find_by_username boolean not null default true;
alter table public.usernames
  add column if not exists verified boolean not null default false;

create or replace function public.find_people(q text)
returns table (phone text, username text, name text, verified boolean)
language plpgsql security definer set search_path = public as $$
begin
  -- Handle-shaped queries only; anything else could smuggle LIKE wildcards.
  if q is null or q !~ '^[a-z0-9_.]{2,32}$' then
    return;
  end if;
  return query
    select u.phone, u.username, u.name, coalesce(u.verified, false)
    from public.usernames u
    -- '_' is a legal handle character but a LIKE wildcard; escape it so
    -- searching a_b does not match axb.
    where lower(u.username) like replace(q, '_', '\_') || '%'
      and coalesce(u.find_by_username, true)
      and not public.is_locked_out(u.phone)
    order by u.username
    limit 25;
end $$;

revoke all on function public.find_people(text) from public;
grant execute on function public.find_people(text) to anon, authenticated;

create or replace function public.claim_numberless(
    code text, uname text, display text default '')
returns boolean
language plpgsql security definer set search_path = public as $$
begin
  -- Codes only. A real number's row is written through RLS by its session.
  if code is null or code !~ '^00[0-9]{10}$' then
    return false;
  end if;
  if uname is null or uname !~ '^[a-z0-9_.]{3,32}$' then
    return false;
  end if;
  if public.is_locked_out(code) then
    return false;
  end if;
  insert into public.usernames (phone, username, name, updated_at)
  values (code, uname, coalesce(display, ''), now())
  -- The same account re-claiming (a display-name change, a retried sign-up)
  -- is fine; CHANGING the handle is not — no session, no proof the code is
  -- yours.
  on conflict (phone) do update
    set name = excluded.name, updated_at = now()
    where usernames.username = excluded.username;
  return found;
exception
  when unique_violation then
    return false; -- the handle belongs to someone else
end $$;

revoke all on function public.claim_numberless(text, text, text) from public;
grant execute on function public.claim_numberless(text, text, text)
  to anon, authenticated;


-- ####################################################################
-- ## docs/identity_backup.sql
-- ####################################################################
-- ============================================================================
-- Encryption recovery (run whole file in Supabase SQL editor; idempotent)
-- ============================================================================
-- One sealed blob per account: the device's identity private key, encrypted
-- ON THE DEVICE under a recovery code the app minted and only the user holds
-- (PBKDF2-HMAC-SHA256 at 120k rounds over a random salt, then AES-256-GCM).
-- The server stores ciphertext it can never open — 80 bits of code entropy
-- stand between a leaked row and the key. This is what lets a reinstall or a
-- new phone restore the SAME identity instead of minting a fresh one, which
-- is the root cause of "sealed to a key this device no longer has".
--
-- Access is the part worth being careful about, because a REPLACED blob is a
-- broken restore (nothing leaks — the thief's blob won't open with the
-- user's code — but the user's backup is gone):
--
--   * Phone accounts ride their session: RLS pins insert/update/select to
--     the JWT's own number, so nobody can read, plant, or replace anybody
--     else's backup.
--   * Numberless accounts (minted '00…' codes) have no session at all, so
--     two SECURITY DEFINER RPCs are their only door, and both refuse
--     anything that is not a '00' inbox. Writes are first-come: the blob
--     can be created but never overwritten anonymously.

create table if not exists public.identity_backups (
  inbox      text primary key,               -- phone digits / account code
  blob       text not null,                  -- sealed archive, never plaintext
  updated_at timestamptz not null default now()
);

alter table public.identity_backups enable row level security;

-- Supabase grants every new public table to anon and authenticated; the
-- policies below only mean anything once that blanket grant is gone.
revoke all on table public.identity_backups from anon;
revoke all on table public.identity_backups from authenticated;
grant select, insert, update on public.identity_backups to authenticated;

drop policy if exists identity_backups_own_select on public.identity_backups;
create policy identity_backups_own_select on public.identity_backups
  for select to authenticated
  using (inbox = regexp_replace(coalesce(auth.jwt() ->> 'phone', ''), '\D', '', 'g'));

drop policy if exists identity_backups_own_insert on public.identity_backups;
create policy identity_backups_own_insert on public.identity_backups
  for insert to authenticated
  with check (inbox = regexp_replace(coalesce(auth.jwt() ->> 'phone', ''), '\D', '', 'g'));

drop policy if exists identity_backups_own_update on public.identity_backups;
create policy identity_backups_own_update on public.identity_backups
  for update to authenticated
  using (inbox = regexp_replace(coalesce(auth.jwt() ->> 'phone', ''), '\D', '', 'g'))
  with check (inbox = regexp_replace(coalesce(auth.jwt() ->> 'phone', ''), '\D', '', 'g'));

-- The numberless door. First write wins: an anonymous caller can create a
-- '00' account's backup but never replace one, because "anonymous" and
-- "allowed to overwrite" cannot coexist without some proof of ownership,
-- and a numberless account has none to offer.
create or replace function public.put_identity_backup(inboxv text, blobv text)
returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if inboxv is null or inboxv !~ '^00\d+$' or blobv is null or blobv = '' then
    return false;
  end if;
  insert into public.identity_backups (inbox, blob)
    values (inboxv, blobv)
    on conflict (inbox) do nothing;
  return exists (
    select 1 from public.identity_backups
    where inbox = inboxv and blob = blobv);
end $$;

-- Reading is also '00'-only: a REAL number's blob is reachable only through
-- its owner's session, so an anonymous caller can never even fetch the
-- ciphertext to brute-force offline.
create or replace function public.get_identity_backup(inboxv text)
returns text
language sql security definer set search_path = public as $$
  select blob from public.identity_backups
  where inbox = inboxv and inboxv ~ '^00\d+$';
$$;


-- ####################################################################
-- ## docs/account_lifecycle.sql
-- ####################################################################
-- Temporary deactivation for the people directory.
-- ============================================================================
-- Run ONCE in the Supabase SQL editor, AFTER docs/directory_numberless.sql
-- (this replaces its find_people with one more filter).
--
-- WHY. "Deactivate my account" has to mean something on the server, or it
-- means nothing: the app can sign somebody out locally, but their @handle
-- stayed findable by everyone. The `hidden` flag is that meaning — a hidden
-- row answers no search, while the handle stays THEIRS (the row keeps
-- existing, so nobody can take the name while they're away). Reactivation is
-- signing back in: the app clears the flag through the same own-row RLS
-- update that set it.
--
-- Deletion is not here on purpose: deleting an account also has to delete
-- the AUTH user, which no RLS policy can do — that is the delete-account
-- Edge Function (service role), which removes every phone-keyed row and the
-- user itself.

alter table public.usernames
  add column if not exists hidden boolean not null default false;

-- The same function docs/directory_numberless.sql installs, with one more
-- line: hidden rows answer no search — not by handle, not by anyone.
create or replace function public.find_people(q text)
returns table (phone text, username text, name text, verified boolean)
language plpgsql security definer set search_path = public as $$
begin
  -- Handle-shaped queries only; anything else could smuggle LIKE wildcards.
  if q is null or q !~ '^[a-z0-9_.]{2,32}$' then
    return;
  end if;
  return query
    select u.phone, u.username, u.name, coalesce(u.verified, false)
    from public.usernames u
    -- '_' is a legal handle character but a LIKE wildcard; escape it so
    -- searching a_b does not match axb.
    where lower(u.username) like replace(q, '_', '\_') || '%'
      and coalesce(u.find_by_username, true)
      and not coalesce(u.hidden, false)
      and not public.is_locked_out(u.phone)
    order by u.username
    limit 25;
end $$;

revoke all on function public.find_people(text) from public;
grant execute on function public.find_people(text) to anon, authenticated;


-- ####################################################################
-- ## docs/admin_users.sql
-- ####################################################################
-- Admin user roster (2026-08-07)
-- ---------------------------------------------------------------------------
-- An owner/admin-only window onto the WHOLE account directory — including the
-- name-only ("numberless") signups whose key is a 00-prefixed account code, not
-- a phone. Those accounts get a real public.usernames row at sign-up
-- (claim_numberless), but they never appear in reports or sanctions, so before
-- this there was no way for staff to see them, or to know how many accounts
-- exist at all.
--
-- platform_roles is service-role only (RLS on, no client policy), so the staff
-- check runs INSIDE these security-definer functions: a client that isn't an
-- owner or admin — as the SERVER sees it, not as the app claims — gets nothing.
-- Neither function returns a phone number: staff act on an account by its
-- @username (the moderation console's "Act on account" already does), so the
-- roster is handles, names and flags, never the directory's phone column.
--
-- Run this AFTER platform_moderation.sql (platform_roles), directory_numberless.sql
-- (verified/find_by_username) and account_lifecycle.sql (hidden).

-- ---------------------------------------------------------------------------
-- Last seen (2026-08-08). A single timestamp per account, bumped by the client
-- on sign-in and every time the app comes to the foreground. It is what lets
-- the moderation roster show who is online now and when everyone else was last
-- around. Only the account itself can bump its own row (the definer function
-- resolves the caller from their JWT), and only staff can read it (through
-- admin_list_users). A NAME-ONLY account has no session, so it can never call
-- touch_last_seen — its last_seen stays null and the roster shows "never seen",
-- which is the honest answer: the app has no way to know it is online.
alter table public.usernames
  add column if not exists last_seen timestamptz;

-- The caller stamps their own last_seen = now(). Resolve the caller to their
-- directory phone by DIGITS (the JWT's phone claim has no '+', the directory
-- stores E.164 with one), the same normalisation public_follow uses.
create or replace function public.touch_last_seen()
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  jwt_phone text := nullif(auth.jwt() ->> 'phone', '');
begin
  if jwt_phone is null then return; end if;
  update public.usernames
     set last_seen = now()
   where regexp_replace(phone, '\D', '', 'g')
       = regexp_replace(jwt_phone, '\D', '', 'g');
end;
$$;

revoke execute on function public.touch_last_seen() from anon;
grant execute on function public.touch_last_seen() to authenticated;

-- How many accounts exist, all kinds. Owner/admin only.
create or replace function public.admin_user_count()
returns bigint
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  ph text := nullif(auth.jwt() ->> 'phone', '');
begin
  if ph is null or not exists (
      select 1 from public.platform_roles r
       where r.phone = ph and r.role in ('owner', 'admin')) then
    raise exception 'not authorised';
  end if;
  return (select count(*) from public.usernames);
end;
$$;

revoke execute on function public.admin_user_count() from anon;
grant execute on function public.admin_user_count() to authenticated;

-- The roster, newest first. numberless is true for a name-only account (its key
-- is a 00-prefixed code, not a phone). No phone column crosses the wire.
--
-- Dropped first: this file gained a last_seen column in the return type, and
-- create-or-replace cannot change a function's OUT parameters ("cannot change
-- return type of existing function") — so a project that ran the earlier
-- version must drop it before the new shape can land. Harmless on a fresh DB.
drop function if exists public.admin_list_users(int, int);
create or replace function public.admin_list_users(lim int default 200, off int default 0)
returns table(
  username    text,
  name        text,
  verified    boolean,
  hidden      boolean,
  numberless  boolean,
  updated_at  timestamptz,
  last_seen   timestamptz)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  ph text := nullif(auth.jwt() ->> 'phone', '');
begin
  if ph is null or not exists (
      select 1 from public.platform_roles r
       where r.phone = ph and r.role in ('owner', 'admin')) then
    raise exception 'not authorised';
  end if;
  return query
    select u.username,
           coalesce(u.name, ''),
           coalesce(u.verified, false),
           coalesce(u.hidden, false),
           (u.phone ~ '^00[0-9]{10}$'),
           u.updated_at,
           u.last_seen
      from public.usernames u
     -- Most-recently-active first: who's online floats to the top, then the
     -- freshest sign-ups (a name-only account has no last_seen, so it sorts
     -- by when its row was written).
     order by coalesce(u.last_seen, u.updated_at) desc
     limit greatest(1, least(lim, 500))
    offset greatest(0, off);
end;
$$;

revoke execute on function public.admin_list_users(int, int) from anon;
grant execute on function public.admin_list_users(int, int) to authenticated;


-- ####################################################################
-- ## docs/community_posts.sql
-- ####################################################################
-- Server-side persistence for community feed posts and marketplace listings.
-- ============================================================================
-- Run ONCE in the Supabase SQL editor.
--
-- WHY. Server posts used to be broadcast-only: a sealed envelope relayed
-- live plus a mailbox copy for whoever was offline that minute. If delivery
-- missed — a member joined later, a mailbox write failed, a device was
-- reinstalled — the listing existed only on its author's phone, which read
-- as "the marketplace doesn't show listings". This table is the durable
-- copy: every post stored ONCE, fetched by members whenever they open or
-- refresh.
--
-- WHAT THE SERVER CAN READ: nothing. `payload` is the same AES-GCM
-- ciphertext the broadcast carries, sealed to the community's secret —
-- which lives only on members' devices, handed over inside invites the
-- server also cannot read. Like the mailbox, possession of the community id
-- fetches ciphertext; the secret is what turns it into posts. Chats are
-- NOT here and never will be: message content stays on devices, full stop.
--
-- Row lifecycle: upserted on post and on every listing update (revision
-- checks on the client keep replays harmless), deleted when the author
-- deletes the post. The client caps a payload the same place the relay
-- does; the CHECK below is the backstop.

create table if not exists public.community_posts (
  community_id text not null,
  post_id      text not null,
  payload      text not null check (char_length(payload) <= 400000),
  updated_at   timestamptz not null default now(),
  primary key (community_id, post_id)
);

create index if not exists community_posts_cid_idx
  on public.community_posts (community_id, updated_at desc);

alter table public.community_posts enable row level security;

-- The mailbox's trust model: the app key may write and read rows, because
-- rows are sealed ciphertext and the community id is unguessable. A delete
-- needs the row's exact ids — the same capability writing needed.
drop policy if exists community_posts_insert on public.community_posts;
create policy community_posts_insert on public.community_posts
  for insert to anon, authenticated with check (true);

drop policy if exists community_posts_select on public.community_posts;
create policy community_posts_select on public.community_posts
  for select to anon, authenticated using (true);

drop policy if exists community_posts_update on public.community_posts;
create policy community_posts_update on public.community_posts
  for update to anon, authenticated using (true) with check (true);

drop policy if exists community_posts_delete on public.community_posts;
create policy community_posts_delete on public.community_posts
  for delete to anon, authenticated using (true);


-- ####################################################################
-- ## docs/ai_usage.sql
-- ####################################################################
-- Server-side rate limit for Okay AI (2026-08-06). Real cost control on top of
-- the client's free-tier UX: a per-caller daily message count the `ai-chat`
-- Edge Function checks BEFORE calling OpenRouter, so a modified client can't
-- run the token bill past the cap.
--
-- Written ONLY by the `ai-chat` function through `ai_note_usage` (service
-- role). No client grants at all — a client can neither read another caller's
-- usage nor reset its own. The cap itself is the function's `AI_DAILY_CAP`
-- env var; this just keeps the tally.
--
-- Run this in the SQL editor. Until it exists the function fails OPEN (no
-- limit), so a missing migration never breaks the assistant — it just leaves
-- the ceiling off.
-- ---------------------------------------------------------------------------

create table if not exists public.ai_usage (
  usage_key text not null,   -- the caller: their phone, or an IP fallback
  day       date not null default current_date,
  count     int  not null default 0,
  primary key (usage_key, day)
);

alter table public.ai_usage enable row level security;
revoke all on table public.ai_usage from anon, authenticated;

-- Atomically bump today's count for a caller and return the new value. The
-- function checks it against the cap; the increment is harmless for a refused
-- request because the refusal happens before any model call, so no tokens are
-- spent — the counter simply keeps climbing while every over-cap request is
-- turned away.
create or replace function public.ai_note_usage(k text)
returns int
language sql
volatile
security definer
set search_path = public
as $$
  insert into public.ai_usage (usage_key, day, count)
  values (k, current_date, 1)
  on conflict (usage_key, day)
    do update set count = public.ai_usage.count + 1
  returning count;
$$;

-- Only the service role (the Edge Function) may call it — never a client.
-- Postgres grants EXECUTE to PUBLIC on a new function, so revoke that too, or
-- anon/authenticated inherit it no matter what the named revokes say.
revoke execute on function public.ai_note_usage(text)
  from public, anon, authenticated;


-- ####################################################################
-- ## docs/ai_training.sql
-- ####################################################################
-- AI training corpus (2026-08-06). The rated Okay AI exchanges a future
-- fine-tune of "your own AI" is built from — collected ONLY from users who
-- opted in to "Help improve Okay AI", and ONLY assistant conversations (never
-- human-to-human chats, which are end-to-end encrypted and never reach a server
-- that can read them).
--
-- Written ONLY by the `ai-feedback` Edge Function (service role). No client
-- grants at all: a client can neither read the corpus nor write to it directly.
-- The `submitter` is a salted hash, not a phone — enough to rate-limit an
-- abuser or drop one person's samples on request, without storing identity.
--
-- The `rating` is the curation signal: train on the thumbs-up (rating = 1)
-- rows, filtered, so the model learns from good exchanges, not nonsense.
--
-- Run this in the SQL editor, then paste the `ai-feedback` function. Until
-- then feedback is best-effort and silently collects nothing.
-- ---------------------------------------------------------------------------

create table if not exists public.ai_training_samples (
  id         bigint generated always as identity primary key,
  prompt     text not null,
  reply      text not null,
  rating     int  not null check (rating in (-1, 1)),
  submitter  text not null default '',
  created_at timestamptz not null default now()
);

alter table public.ai_training_samples enable row level security;
-- Take back every grant Supabase gives a new public table, and add none: the
-- ai-feedback function (service role) is the only writer, and nobody reads it
-- through the API — the corpus is exported for training out of band.
revoke all on table public.ai_training_samples from anon, authenticated;
revoke all on sequence public.ai_training_samples_id_seq from anon, authenticated;


-- ####################################################################
-- ## docs/legal_documents.sql
-- ####################################################################
-- Owner-editable legal documents (2026-08-06). The Terms of Service and
-- Privacy Policy, so the owner can update them from inside the app without
-- shipping a new build. A single row (id = 1).
--
-- READABLE BY EVERYONE — the app fetches the current text on launch, the same
-- way it fetches any public config; the documents are public policy. WRITABLE
-- ONLY by the `legal-set` Edge Function (service role), which first checks the
-- caller is the platform owner. No client write grants at all.
--
-- The `version` is what the acceptance gate compares against: bumping it (which
-- publishing does) asks every user to agree again.
--
-- Run this in the SQL editor, then paste the `legal-set` function. Until then
-- the app shows its built-in documents and the owner editor says it isn't set
-- up yet.
-- ---------------------------------------------------------------------------

create table if not exists public.legal_documents (
  id           int primary key default 1,
  terms        jsonb not null default '[]'::jsonb,
  privacy      jsonb not null default '[]'::jsonb,
  version      int  not null default 0,
  last_updated text not null default '',
  edited_at    timestamptz not null default now(),
  constraint legal_documents_singleton check (id = 1)
);

alter table public.legal_documents enable row level security;

-- Anyone may READ the current documents (public policy, fetched on launch).
drop policy if exists legal_documents_read on public.legal_documents;
create policy legal_documents_read on public.legal_documents
  for select using (true);
grant select on table public.legal_documents to anon, authenticated;

-- Nobody writes through the API. The legal-set function (service role, which
-- bypasses RLS) is the only writer, and it checks platform ownership first.
revoke insert, update, delete on table public.legal_documents
  from anon, authenticated;


-- ####################################################################
-- ## docs/public_feed_edit.sql
-- ####################################################################
-- Editing a public-feed post — a narrow, deliberate opening in the otherwise
-- append-only design (docs/public_feed.sql revokes UPDATE outright, because an
-- editable public post with no history is a way to bait people and then rewrite
-- it). This grants exactly enough to fix a post, and no more:
--
--   * only the AUTHOR, and only while not silenced (same as posting),
--   * only within a SHORT WINDOW after posting (15 minutes) — long enough for a
--     typo, too short to rewrite a post people have already acted on,
--   * only the BODY (and the edited_at stamp) — never author, never counts,
--   * and every edit is STAMPED, so an edited post says so.
--
-- The re-moderation is client-side, exactly like the original post: the app
-- screens the new text through the moderation-screen function before it calls
-- the update. The server enforces WHO and WHEN; the client enforces WHAT, the
-- same split posting already uses.
--
-- Idempotent, and safe to run more than once. Apply AFTER docs/public_feed.sql
-- and docs/creator_subscriptions.sql: it re-creates the public_feed view as the
-- final word on its shape, carrying paid + sub_cents (from creator
-- subscriptions) AND the new edited_at — so running this also restores the
-- paywall columns if a re-run of public_feed.sql had dropped them.

-- 1. The stamp: null means never edited.
alter table public.public_posts
  add column if not exists edited_at timestamptz;

-- public_posts is granted SELECT column-by-column (never table-wide, so the
-- phone stays unreadable), and the feed view runs security_invoker — so a NEW
-- column is invisible through the view until it's granted too, exactly like
-- paid/sub_cents were.
--
-- paid/sub_cents are RE-GRANTED here, not merely assumed: this file recreates
-- the view carrying them, and it runs LAST. If public_feed.sql was re-run
-- after creator_subscriptions.sql, its table-wide `revoke select … from anon`
-- wiped those column grants while leaving the view that reads them — and the
-- whole feed then fails for anon with "permission denied for table
-- public_posts" (a security_invoker view needs the caller to hold every column
-- it selects). Granting them here makes this file self-sufficient: run it and
-- the feed reads, whatever order came before.
grant select (paid, sub_cents, edited_at)
  on public.public_posts to anon, authenticated;

-- 2. Give back UPDATE, but only on the two columns an edit may touch. A
-- column-level grant means an UPDATE of anything else is refused before RLS is
-- even consulted.
grant update (body, edited_at) on public.public_posts to authenticated;

-- 3. The policy: your own post, not silenced, inside the window. Both USING
-- (which rows you may target) and WITH CHECK (what the row may become) carry
-- the window, so the edit is refused the moment it closes.
drop policy if exists public_posts_update_own on public.public_posts;
create policy public_posts_update_own on public.public_posts
  for update to authenticated
  using (
    author_phone = (auth.jwt() ->> 'phone')
    and not public.is_silenced(author_phone)
    and created_at > now() - interval '15 minutes'
  )
  with check (
    author_phone = (auth.jwt() ->> 'phone')
    and created_at > now() - interval '15 minutes'
  );

-- 4. The feed view, now also carrying edited_at (and still paid + sub_cents).
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
  public.public_post_spark_cents(p.id)  as spark_cents,
  p.paid,
  p.sub_cents,
  -- Appended LAST on purpose: create-or-replace can only add view columns at
  -- the end, never insert one mid-list (it reads as renaming the column there).
  p.edited_at
from public.public_posts p;

grant select on public.public_feed to anon, authenticated;


-- ####################################################################
-- ## docs/public_forum.sql
-- ####################################################################
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
-- voter_phone is never granted, and the policy below shows you only your row.
revoke select on table public.public_forum_votes from anon, authenticated;
grant select (post_id, dir, created_at)
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


-- ####################################################################
-- ## docs/community_notes.sql
-- ####################################################################
-- Community notes: reader-written fact-checks on public-feed posts, the way X's
-- Community Notes work. Anyone signed in may add a note giving context to a
-- post; anyone signed in may rate a note helpful or not; a note enough readers
-- find helpful is shown on the post (the client decides "shown" from the
-- tallies — see CommunityNote.isShown).
-- ============================================================================
-- Run ONCE in the Supabase SQL editor, AFTER docs/platform_moderation.sql and
-- docs/public_feed.sql — this references public.public_posts (the post a note
-- is about) and leans on public.is_locked_out() / public.is_silenced().
--
-- PLAINTEXT THE SERVER CAN READ, ON PURPOSE — the public-feed rule. A note on a
-- world-readable post has no key to seal under, and (like the feed itself) it is
-- server-moderated, so the text is public. What stays protected is the author's
-- and rater's phone number: clients are granted every column but the phone, and
-- attribution is by username, exactly as the public feed does it.
--
-- ORDER MATTERS: tables, then functions (bodies are parsed at creation, so the
-- tables they read must exist), then privileges and policies, then the view.

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------
create table if not exists public.community_notes (
  -- Client-generated, so a device recognises its own note coming back.
  id              text primary key,
  -- The post this note is about. Cascade so a deleted post takes its notes.
  post_id         text not null
                    references public.public_posts(id) on delete cascade,
  -- E.164 digits. Ownership only — never granted to a client role below.
  author_phone    text not null,
  author_username text not null default '',
  author_name     text not null default '',
  author_verified boolean not null default false,
  -- One to 280 characters of context. A note has to say something.
  body            text not null check (char_length(body) between 1 and 280),
  created_at      timestamptz not null default now()
);

-- One rating per person per note, changeable — like a forum vote, you can flip
-- helpful/not or take it back (update/delete on your own row, below).
create table if not exists public.community_note_ratings (
  note_id     text not null
                references public.community_notes(id) on delete cascade,
  rater_phone text not null,
  helpful     boolean not null,
  created_at  timestamptz not null default now(),
  primary key (note_id, rater_phone)
);

create index if not exists community_notes_post_idx
  on public.community_notes (post_id, created_at desc);
create index if not exists community_notes_author_idx
  on public.community_notes (author_phone);
create index if not exists community_note_ratings_note_idx
  on public.community_note_ratings (note_id);

alter table public.community_notes        enable row level security;
alter table public.community_note_ratings enable row level security;

-- ---------------------------------------------------------------------------
-- 2. Functions (the tables above have to exist first)
-- ---------------------------------------------------------------------------
-- Helpful / not-helpful tallies. SECURITY DEFINER because a rating row is
-- readable only by the person who cast it (the policy below), so counting as
-- the caller would see only your own rating — the same trick the feed's like
-- and poll counters use. Running as owner makes the totals true while who
-- rated stays private.
create or replace function public.community_note_helpful(n text)
returns bigint
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::bigint
    from public.community_note_ratings where note_id = n and helpful;
$$;

create or replace function public.community_note_nothelpful(n text)
returns bigint
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::bigint
    from public.community_note_ratings where note_id = n and not helpful;
$$;

-- ---------------------------------------------------------------------------
-- 3. Column privileges
-- ---------------------------------------------------------------------------
-- THE PHONE COLUMN, PROPERLY — Supabase grants every new table table-wide
-- SELECT, and Postgres can't carve a column out of that, so revoke the whole
-- grant and hand back the readable columns.
revoke select on table public.community_notes from anon, authenticated;
grant select (id, post_id, author_username, author_name, author_verified,
              body, created_at)
  on public.community_notes to anon, authenticated;

-- Your own rating comes back so the app can highlight the button you pressed;
-- rater_phone is never granted, and the policy shows you only your row.
revoke select on table public.community_note_ratings from anon, authenticated;
grant select (note_id, helpful, created_at)
  on public.community_note_ratings to authenticated;

-- Writing is by whole row; the policies decide whose row it may be.
grant insert, delete on public.community_notes to authenticated;
-- A rating can be changed or taken back.
grant insert, update, delete on public.community_note_ratings to authenticated;

-- No UPDATE on a note (append-only, like a forum post): an UPDATE matching no
-- policy affects zero rows without raising, which reads like success. Taking
-- the privilege away makes the refusal explicit.
revoke update on public.community_notes from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Policies (the functions above have to exist first)
-- ---------------------------------------------------------------------------
-- Readable by anyone with the app, except notes by a banned/suspended account.
drop policy if exists community_notes_read on public.community_notes;
create policy community_notes_read on public.community_notes
  for select to anon, authenticated
  using (not public.is_locked_out(author_phone));

-- Add a note only as yourself, and only while you are allowed to.
drop policy if exists community_notes_insert_own on public.community_notes;
create policy community_notes_insert_own on public.community_notes
  for insert to authenticated
  with check (
    author_phone = (auth.jwt() ->> 'phone')
    and not public.is_silenced(author_phone)
  );

drop policy if exists community_notes_delete_own on public.community_notes;
create policy community_notes_delete_own on public.community_notes
  for delete to authenticated
  using (author_phone = (auth.jwt() ->> 'phone'));

-- Ratings: see only your own, cast/change/take back only your own, and only
-- while allowed to interact.
drop policy if exists community_note_ratings_read_own
  on public.community_note_ratings;
create policy community_note_ratings_read_own on public.community_note_ratings
  for select to authenticated
  using (rater_phone = (auth.jwt() ->> 'phone'));

drop policy if exists community_note_ratings_insert_own
  on public.community_note_ratings;
create policy community_note_ratings_insert_own on public.community_note_ratings
  for insert to authenticated
  with check (
    rater_phone = (auth.jwt() ->> 'phone')
    and not public.is_silenced(rater_phone)
  );

drop policy if exists community_note_ratings_update_own
  on public.community_note_ratings;
create policy community_note_ratings_update_own on public.community_note_ratings
  for update to authenticated
  using (rater_phone = (auth.jwt() ->> 'phone'))
  with check (rater_phone = (auth.jwt() ->> 'phone'));

drop policy if exists community_note_ratings_delete_own
  on public.community_note_ratings;
create policy community_note_ratings_delete_own on public.community_note_ratings
  for delete to authenticated
  using (rater_phone = (auth.jwt() ->> 'phone'));

-- ---------------------------------------------------------------------------
-- 5. What clients actually read
-- ---------------------------------------------------------------------------
-- A view with no phone column in it at all. security_invoker keeps the caller's
-- RLS in force, which is what hides a banned author's notes.
drop view if exists public.community_notes_view;
create view public.community_notes_view
with (security_invoker = on) as
select
  n.id,
  n.post_id,
  n.author_username,
  n.author_name,
  n.author_verified,
  n.body,
  n.created_at,
  public.community_note_helpful(n.id)    as helpful_count,
  public.community_note_nothelpful(n.id) as not_helpful_count
from public.community_notes n;

grant select on public.community_notes_view to anon, authenticated;


-- ####################################################################
-- ## docs/paid_servers.sql
-- ####################################################################
-- Paid servers (2026-08-06). The membership half of creator subscriptions:
-- who has paid to be in a paid server, verified from a store receipt.
--
-- A paid server's traffic is already END-TO-END SEALED under its own secret,
-- so this is NOT access-control over readable content — the server never sees
-- or stores a message. It records who holds an active membership pass, so the
-- join can be gated and (the hardening follow-up) the owner's device can
-- release the secret only to a verified-paid joiner.
--
-- `community_passes` is written ONLY by the `community-subscribe` Edge Function
-- (service role), after it verifies the Apple receipt. There are NO client
-- grants on the tables at all; the definer functions below are the only doors,
-- and none of them ever returns a phone number.
--
-- Run this in the Supabase SQL editor, then paste the `community-subscribe`
-- function. Until then paid servers run in test/simulation only (the client's
-- local pass drives the demo).
-- ---------------------------------------------------------------------------

-- Both ends stay off the client. subscriber_phone is the payer; server_id is
-- the community id. last_txn_id dedupes a receipt so one purchase grants one
-- month. Keyed by (subscriber, server): one live pass per server per account.
create table if not exists public.community_passes (
  subscriber_phone text not null,
  server_id        text not null,
  expires_at       timestamptz not null,
  product_id       text not null default '',
  last_txn_id      text not null default '',
  updated_at       timestamptz not null default now(),
  primary key (subscriber_phone, server_id)
);

alter table public.community_passes enable row level security;
revoke all on table public.community_passes from anon, authenticated;

-- One row per consumed receipt, so the same signed transaction can't be
-- replayed to buy membership of a dozen servers.
create table if not exists public.community_sub_receipts (
  txn_id     text primary key,
  created_at timestamptz not null default now()
);
alter table public.community_sub_receipts enable row level security;
revoke all on table public.community_sub_receipts from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Read gates (security definer — the only doors). A client can ask about its
-- OWN passes; it can never grant itself one or read anybody else's.
-- ---------------------------------------------------------------------------

-- Whether the caller holds an active membership pass to [s] (a server id).
create or replace function public.community_pass_active(s text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
      from public.community_passes p
     where p.subscriber_phone = (auth.jwt() ->> 'phone')
       and p.server_id = s
       and p.expires_at > now()
  );
$$;

-- The caller's own active passes — server id + expiry — for reconciling the
-- local list on start. Only ever your own rows; no phone ever returned.
create or replace function public.community_my_passes()
returns table(server_id text, expires_at timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  select p.server_id, p.expires_at
    from public.community_passes p
   where p.subscriber_phone = (auth.jwt() ->> 'phone')
     and p.expires_at > now();
$$;

grant execute on function public.community_pass_active(text) to authenticated;
grant execute on function public.community_my_passes() to authenticated;

