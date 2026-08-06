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
grant select (edited_at) on public.public_posts to anon, authenticated;

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
