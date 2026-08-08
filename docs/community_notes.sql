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
