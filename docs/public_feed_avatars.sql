-- Public newsfeed: carry the author's AVATAR on the post, beside the name and
-- the badge it already carries.
--
-- Reported as "it doesn't show the right profile pictures on my other phone":
-- a second account, with no chats, saw a timeline of letter avatars. That was
-- not a rendering fault. `FeedAvatar` resolves a face through `knownUserFor`,
-- which answers only for YOURSELF or a chat CONTACT — and the feed row carried
-- nothing else to draw, because `public_posts` has only ever held
-- author_username, author_name and author_verified. A stranger on the public
-- timeline is exactly the person a device cannot know, so the one surface
-- built for meeting people was the one that could never show their face.
--
-- **The snapshot is the existing pattern, not a new exposure.** author_name
-- and author_verified are already written onto the post at post time — the
-- author's own presentation, published because they chose to post in public.
-- The avatar joins them on the same terms: only somebody who posts publicly
-- publishes a face, and only for the post they chose to make. That is why this
-- is on the POST rather than in the `usernames` directory, which would publish
-- the avatar of everyone who has an account, including people who never post,
-- to anyone who can guess a handle.
--
-- **The phone is deliberately NOT among these columns**, and nothing here
-- needs it: the client re-salts a legacy avatar seed (lib/util/avatar_seed.dart)
-- with the author's HANDLE, which a public post already carries, and only
-- falls back to a number when there is no handle at all.
--
-- A contact this device really knows still wins over the snapshot, so their
-- face stays live; the snapshot is what a STRANGER draws with. That split also
-- answers the one cost of snapshotting — a changed avatar does not reach back
-- into old posts, exactly as a changed display name already does not.
--
-- Idempotent, and safe to run more than once. Apply AFTER docs/public_feed.sql,
-- docs/creator_subscriptions.sql and docs/public_feed_edit.sql: like that last
-- one, this re-creates the public_feed view as the final word on its shape,
-- carrying paid + sub_cents + edited_at AND the six new columns.

-- 1. The columns. Empty is "said nothing", which every reader already treats
--    as "fall back to the initial", so an old row needs no migration.
alter table public.public_posts
  add column if not exists author_avatar_color  text not null default '',
  add column if not exists author_avatar_color2 text not null default '',
  add column if not exists author_emoji         text not null default '',
  add column if not exists author_avatar_seed   text not null default '',
  add column if not exists author_avatar_face   text not null default '',
  add column if not exists author_avatar_gif    text not null default '';

-- Bounded, because these are client-supplied and a public table is the wrong
-- place to discover somebody pasting a megabyte into a colour. The face is a
-- JSON selection (a couple of hundred bytes in practice) and the GIF is a URL
-- the client already refuses past 400 characters; these are the ceilings, not
-- the expected sizes.
do $$
begin
  alter table public.public_posts
    add constraint public_posts_avatar_len check (
      length(author_avatar_color)  <= 16
      and length(author_avatar_color2) <= 16
      and length(author_emoji)      <= 16
      and length(author_avatar_seed) <= 64
      and length(author_avatar_face) <= 2000
      and length(author_avatar_gif)  <= 512
    );
exception
  when duplicate_object then null;
end $$;

-- 2. public_posts is granted SELECT column-by-column — never table-wide, so
--    author_phone stays unreadable — and the feed view runs security_invoker,
--    so a new column is invisible through the view until it is granted too.
--    paid/sub_cents/edited_at are re-granted here for the same reason
--    public_feed_edit.sql re-grants its predecessors': this file runs LAST, and
--    a re-run of public_feed.sql in between would have wiped them with its
--    table-wide revoke while leaving the view that reads them, failing the
--    whole feed for anon with "permission denied for table public_posts".
grant select (paid, sub_cents, edited_at,
              author_avatar_color, author_avatar_color2, author_emoji,
              author_avatar_seed, author_avatar_face, author_avatar_gif)
  on public.public_posts to anon, authenticated;

-- The author writes their own, and only their own: the INSERT policy already
-- pins author_phone to the caller's JWT, so there is no way to publish a face
-- onto somebody else's post. UPDATE stays limited to body + edited_at, so an
-- edit cannot quietly swap the avatar on a post people have already read.
grant insert (author_avatar_color, author_avatar_color2, author_emoji,
              author_avatar_seed, author_avatar_face, author_avatar_gif)
  on public.public_posts to authenticated;

-- 3. The feed view, now also carrying the avatar.
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
  p.edited_at,
  -- Appended LAST on purpose: create-or-replace can only add view columns at
  -- the end, never insert one mid-list (it reads as renaming the column there).
  p.author_avatar_color,
  p.author_avatar_color2,
  p.author_emoji,
  p.author_avatar_seed,
  p.author_avatar_face,
  p.author_avatar_gif
from public.public_posts p;

grant select on public.public_feed to anon, authenticated;
