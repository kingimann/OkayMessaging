-- Deletes the NAME-ONLY (numberless) accounts left behind when that sign-up
-- route was removed on 2026-08-20.
--
-- WHAT ONE IS. Its identity is an ACCOUNT CODE — '00' followed by ten digits
-- (`AccountCode.mint`) — sitting in `usernames.phone` where a real E.164
-- number would be. It has no Supabase auth user and never had one, which is
-- the whole reason the app gated it: nearly every table here is granted `to
-- authenticated`, so such an account could only ever write to what the ANON
-- key reaches. The pattern below is the app's own — `admin_list_users`
-- (docs/admin_users.sql) tests for exactly '^00[0-9]{10}$' to decide whether
-- a directory row is a name-only account.
--
-- **'999…' CODES ARE A DIFFERENT THING AND ARE NOT TOUCHED.** Those are minted
-- server-side by `email-account` for an account that verified an EMAIL; they
-- carry a real session and are ordinary accounts. The anchor above is what
-- keeps them out — do not loosen it to '^00' or to a length test.
--
-- ONE LIST DRIVES BOTH HALVES. `_owned` below names every table that can hold
-- a row belonging to an account, and both the survey and the deletion read it.
-- Two hand-kept lists is how a table gets surveyed and then not deleted (or
-- worse, deleted without ever being surveyed), so there is only one.
--
-- EVERY LOOKUP IS GUARDED BY `to_regclass`. This runs against whatever the
-- project actually has, not against what the migrations would build — a table
-- from a migration that was never applied is skipped rather than aborting the
-- run half way through.
--
-- HOW TO RUN IT. The preamble and PART 1 are read-only: select everything
-- ABOVE the PART 2 banner and run that first, then read what it says. When
-- you are satisfied, run the whole file — the preamble is idempotent and the
-- survey is harmless to repeat, and both halves need the temp tables the
-- preamble builds, which live only for the session that created them.

-- ===========================================================================
-- PREAMBLE — the two lists both halves read.
-- ===========================================================================

drop table if exists _owned;
drop table if exists _survey;
drop table if exists _doomed;

-- The accounts. Derived ONCE, so the survey and the deletion cannot possibly
-- be talking about different sets of rows.
create temporary table _doomed as
  select phone from public.usernames where phone ~ '^00[0-9]{10}$';

create temporary table _owned (
  ord   int,      -- delete order: children before parents
  label text,
  tbl   text,
  col   text,
  del   boolean   -- false = surveyed but deliberately never deleted
);

insert into _owned (ord, label, tbl, col, del) values
  -- The public feed. `public_post_*` cascade from their own post, but a
  -- doomed account's like on SOMEBODY ELSE'S post has no cascade to ride.
  ( 1, 'public_post_likes',         'public_post_likes',          'liker_phone',      true),
  ( 2, 'public_post_views',         'public_post_views',          'viewer_phone',     true),
  ( 3, 'public_post_votes',         'public_post_votes',          'voter_phone',      true),
  ( 4, 'public_post_sparks',        'public_post_sparks',         'sparker_phone',    true),
  ( 5, 'public_posts',              'public_posts',               'author_phone',     true),
  ( 6, 'public_follows (follower)', 'public_follows',             'follower_phone',   true),
  ( 7, 'public_follows (followed)', 'public_follows',             'followed_phone',   true),
  -- The public forum.
  ( 8, 'public_forum_comment_votes','public_forum_comment_votes', 'voter_phone',      true),
  ( 9, 'public_forum_votes',        'public_forum_votes',         'voter_phone',      true),
  (10, 'public_forum_comments',     'public_forum_comments',      'author_phone',     true),
  (11, 'public_forum_posts',        'public_forum_posts',         'author_phone',     true),
  (12, 'public_forum_sections',     'public_forum_sections',      'created_by_phone', true),
  -- Community notes, marketplace, promotions.
  (13, 'community_note_ratings',    'community_note_ratings',     'rater_phone',      true),
  (14, 'community_notes',           'community_notes',            'author_phone',     true),
  (15, 'market_reviews',            'market_reviews',             'author_phone',     true),
  (16, 'market_listings',           'market_listings',            'author_phone',     true),
  (17, 'post_promotions',           'post_promotions',            'promoter_phone',   true),
  -- Membership and presence.
  (18, 'community_voice_presence',  'community_voice_presence',   'member_phone',     true),
  (19, 'community_bans',            'community_bans',             'member_phone',     true),
  (20, 'community_members',         'community_members',          'member_phone',     true),
  (21, 'community_passes',          'community_passes',           'subscriber_phone', true),
  (22, 'creator_subscriptions',     'creator_subscriptions',      'subscriber_phone', true),
  (23, 'chat_members',              'chat_members',               'member_phone',     true),
  (24, 'call_rosters',              'call_rosters',               'member_phone',     true),
  -- Per-account settings.
  (25, 'identity_verifications',    'identity_verifications',     'phone',            true),
  (26, 'payment_settings',          'payment_settings',           'phone',            true),
  (27, 'email_claims',              'email_claims',               'phone',            true),
  -- The sealed identity backup. This is the one table that will really have
  -- rows: its two definer RPCs are anon-callable and refuse anything that is
  -- NOT a '00' inbox, so it exists solely for these accounts.
  (28, 'identity_backups',          'identity_backups',           'inbox',            true),
  -- Undelivered ciphertext addressed to them. There is no sender column — the
  -- sender is inside the sealed envelope — so this is the one direction there
  -- is. Nothing can read these rows once the account is gone: the key never
  -- left that device.
  (29, 'mailbox',                   'mailbox',                    'inbox',            true),
  -- The directory row LAST. It is what `find_people` and every handle lookup
  -- answer from, so removing it is what actually makes the account gone — and
  -- doing it last means a failure anywhere above leaves the account intact
  -- rather than half-erased and unreachable.
  (99, 'usernames',                 'usernames',                  'phone',            true),

  -- ---- Surveyed, never deleted -------------------------------------------
  -- STOP: deleting a `community_servers` row cascades to its channels, roles
  -- and whole member roster — somebody else's server, destroyed to tidy up
  -- one directory row. Same for a chat. These should all be zero: creating
  -- one needs a session these accounts have never had. If one is not, decide
  -- by hand rather than letting this script decide for you.
  (-1, 'STOP: community_servers (owned)', 'community_servers', 'owner_phone', false),
  (-1, 'STOP: server_directory (owned)',  'server_directory',  'owner_phone', false),
  (-1, 'STOP: direct_chats (owned)',      'direct_chats',      'owner_phone', false),
  -- KEPT: a sanction or an area ban on one of these codes stays. Keeping it
  -- costs nothing; removing it is the one direction that loses safety — it
  -- would quietly un-ban the code. (`moderation_log` is append-only and
  -- hash-chained, docs/audit_log_immutable.sql, so it could not be touched
  -- here even deliberately.)
  (-1, 'KEPT: account_sanctions',   'account_sanctions',  'phone', false),
  (-1, 'KEPT: account_area_bans',   'account_area_bans',  'phone', false);

-- ===========================================================================
-- PART 1 — the survey. Read-only. Who they are, and what they own.
-- ===========================================================================

select phone, username, name, updated_at, last_seen, hidden
  from public.usernames
 where phone ~ '^00[0-9]{10}$'
 order by updated_at;

-- ZERO IS THE EXPECTED ANSWER ALMOST EVERYWHERE, and that is the point of
-- running this: without an auth user these accounts cannot write to an
-- `authenticated`-only table, so the only rows they can really have are in
-- `mailbox` and `identity_backups`, the two the anon key reaches. Anything
-- else non-zero means a policy was once looser than it is now — worth
-- understanding BEFORE part 2 runs, not after.
create temporary table _survey (label text, rows bigint, deleting boolean);

do $$
declare r record; n bigint;
begin
  for r in select * from _owned order by ord, label loop
    if to_regclass('public.' || r.tbl) is null then
      insert into _survey values (r.label || '  (no such table here)', null, false);
      continue;
    end if;
    execute format(
      'select count(*) from public.%I x join _doomed d on x.%I = d.phone',
      r.tbl, r.col) into n;
    insert into _survey values (r.label, n, r.del);
  end loop;
end $$;

select * from _survey order by rows desc nulls last, label;

-- ===========================================================================
-- PART 2 — the deletion. Run only after reading part 1.
-- ===========================================================================
--
-- ONE TRANSACTION, so it is all or nothing.

begin;

-- What is about to go, echoed so the transcript records it.
select count(*) as accounts_to_delete from _doomed;

do $$
declare r record; n bigint;
begin
  for r in select * from _owned where del order by ord loop
    if to_regclass('public.' || r.tbl) is null then continue; end if;
    execute format(
      'delete from public.%I where %I in (select phone from _doomed)',
      r.tbl, r.col);
    get diagnostics n = row_count;
    if n > 0 then raise notice 'deleted % from %', n, r.label; end if;
  end loop;
end $$;

-- Read this before committing. Expect 0.
select count(*) as still_there
  from public.usernames where phone ~ '^00[0-9]{10}$';

commit;
