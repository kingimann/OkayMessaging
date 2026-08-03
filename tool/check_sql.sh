#!/bin/sh
# Run the migrations against a real Postgres, then test what they enforce.
# =============================================================================
#     sh tool/check_sql.sh
#
# WHY THIS EXISTS. These files only ever ran in the Supabase dashboard, so the
# first reader was always a person pasting them, and two bugs shipped that way
# in one file:
#
#   * a SQL function's body is parsed at creation time, so functions placed
#     above the tables they read failed with "relation does not exist";
#   * `revoke select (col)` looks like it protects a column and does nothing
#     when the role holds a table-wide grant — which Supabase gives every new
#     table in public. Every poster's phone number was readable.
#
# Neither is visible by reading carefully. Both take seconds to catch here.
#
# Spins up a throwaway cluster in /tmp, applies a small Supabase-shaped harness
# (the anon/authenticated roles, an auth.jwt() stub, the default grants), then
# runs schema.sql and the migrations in order and asserts the security
# properties that matter.

set -e

PGBIN=/usr/lib/postgresql/16/bin
[ -d "$PGBIN" ] || PGBIN=$(dirname "$(command -v initdb 2>/dev/null || echo /nonexistent)")
if [ ! -x "$PGBIN/initdb" ]; then
  echo "postgres not installed — skipping SQL checks"
  echo "  (apt-get install -y postgresql to enable them)"
  exit 0
fi

DATA=/tmp/okay_pgdata
RUN=/tmp/okay_pgrun
PORT=5433
export PATH="$PGBIN:$PATH"

id pg >/dev/null 2>&1 || useradd -m pg
rm -rf "$DATA"; mkdir -p "$DATA" "$RUN"; chown -R pg "$DATA" "$RUN"

su pg -c "PATH=$PGBIN:\$PATH initdb -D $DATA -A trust" >/tmp/okay_initdb.log 2>&1
su pg -c "PATH=$PGBIN:\$PATH pg_ctl -D $DATA -o '-k $RUN -p $PORT -c listen_addresses=' -l /tmp/okay_pg.log start" >/dev/null 2>&1
trap 'su pg -c "PATH=$PGBIN:\$PATH pg_ctl -D $DATA -m immediate stop" >/dev/null 2>&1 || true' EXIT

# Wait for it rather than sleeping blind.
i=0
until su pg -c "PATH=$PGBIN:\$PATH pg_isready -h $RUN -p $PORT" >/dev/null 2>&1; do
  i=$((i + 1)); [ "$i" -gt 30 ] && { echo "postgres did not start"; cat /tmp/okay_pg.log; exit 1; }
  sleep 1
done

WORK=/tmp/okay_sqlcheck
rm -rf "$WORK"; mkdir -p "$WORK"

cat > "$WORK/harness.sql" <<'SQL'
do $$ begin
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role nologin; end if;
end $$;
create schema if not exists auth;
create or replace function auth.jwt() returns jsonb
language sql stable as $$
  select coalesce(current_setting('request.jwt.claims', true), '{}')::jsonb;
$$;
grant usage on schema public, auth to anon, authenticated, service_role;
-- Supabase grants new public tables to these roles; the column checks below
-- only mean anything with this in place.
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;

-- Enough of Supabase Storage for the bucket policies to apply.
create schema if not exists storage;
create table if not exists storage.buckets (
  id text primary key, name text, public boolean default false,
  file_size_limit bigint);
create table if not exists storage.objects (
  id uuid primary key default gen_random_uuid(), bucket_id text, name text,
  owner uuid, created_at timestamptz default now());
alter table storage.objects enable row level security;
grant usage on schema storage to anon, authenticated, service_role;
grant select, insert, update, delete on storage.objects to anon, authenticated;
grant select on storage.buckets to anon, authenticated;
SQL

# The assertions. Each raises on failure, so ON_ERROR_STOP fails the run.
cat > "$WORK/assert.sql" <<'SQL'
create or replace function pg_temp.expect_fail(stmt text, what text)
returns void language plpgsql as $$
begin
  begin
    execute stmt;
  exception when others then
    raise notice '  ok   %', what;
    return;
  end;
  raise exception 'SECURITY CHECK FAILED: % was permitted', what;
end $$;

create or replace function pg_temp.expect_ok(stmt text, what text)
returns void language plpgsql as $$
begin
  execute stmt;
  raise notice '  ok   %', what;
exception when others then
  raise exception 'CHECK FAILED: % — %', what, sqlerrm;
end $$;

create or replace function pg_temp.as_user(p text) returns void
language sql as $$ select set_config('request.jwt.claims',
  json_build_object('phone', p)::text, false)::void; $$;

-- A banned account and a timed-out one.
insert into public.account_sanctions (phone, kind, reason) values
  ('15550009999', 'ban', 'test') on conflict (phone) do nothing;
insert into public.account_sanctions (phone, kind, until) values
  ('15550003333', 'timeout', now() + interval '1 hour')
  on conflict (phone) do nothing;

set role authenticated;
select pg_temp.as_user('15550001111');

select pg_temp.expect_ok(
  $$insert into public.public_posts (id, author_phone, author_username, body)
    values ('t_p1','15550001111','alice','hello')$$,
  'you can post as yourself');

select pg_temp.expect_fail(
  $$insert into public.public_posts (id, author_phone, author_username, body)
    values ('t_p2','15550002222','bob','impersonated')$$,
  'you cannot post as somebody else');

select pg_temp.expect_fail(
  $$select author_phone from public.public_posts$$,
  'a client cannot read an author phone');

select pg_temp.expect_fail(
  $$select * from public.public_posts$$,
  'select * is refused (it would include the phone)');

select pg_temp.expect_ok(
  $$select id, author_username, body, like_count from public.public_feed$$,
  'the feed view reads fine');

select pg_temp.expect_fail(
  $$select liker_phone from public.public_post_likes$$,
  'a client cannot read who liked something');

select pg_temp.expect_ok(
  $$insert into public.public_post_likes (post_id, liker_phone)
    values ('t_p1','15550001111')$$,
  'you can like a post');

select pg_temp.expect_fail(
  $$insert into public.public_post_likes (post_id, liker_phone)
    values ('t_p1','15550002222')$$,
  'you cannot like as somebody else');

-- A timed-out account is refused at the database, not merely in the UI.
select pg_temp.as_user('15550003333');
select pg_temp.expect_fail(
  $$insert into public.public_posts (id, author_phone, author_username, body)
    values ('t_p3','15550003333','carl','silenced')$$,
  'a timed-out account cannot post');

reset role;
update public.account_sanctions set until = now() - interval '1 minute'
  where phone = '15550003333';
set role authenticated;
select pg_temp.as_user('15550003333');
select pg_temp.expect_ok(
  $$insert into public.public_posts (id, author_phone, author_username, body)
    values ('t_p4','15550003333','carl','allowed again')$$,
  'an expired time-out lifts by itself');

-- A banned author disappears from the feed.
reset role;
insert into public.public_posts (id, author_phone, author_username, body)
  values ('t_p5','15550009999','banned','hidden');
set role authenticated;
select pg_temp.as_user('15550001111');
do $$ begin
  if (select count(*) from public.public_feed where author_username='banned') <> 0 then
    raise exception 'SECURITY CHECK FAILED: a banned author is still in the feed';
  end if;
  raise notice '  ok   a banned author leaves the feed';
end $$;

-- Editing a public post is not offered to anyone.
select pg_temp.expect_fail(
  $$update public.public_posts set body = 'rewritten' where id = 't_p1'$$,
  'rewriting a public post is refused');
-- Belt and braces: even if the privilege were there, RLS grants no UPDATE
-- policy, so assert the text really is untouched rather than trusting the
-- statement to have errored. An UPDATE that matches no policy affects zero
-- rows *without* raising, which is how this check first passed while asserting
-- the wrong thing.
do $$ begin
  if (select body from public.public_feed where id='t_p1') <> 'hello' then
    raise exception 'SECURITY CHECK FAILED: a public post was rewritten';
  end if;
  raise notice '  ok   the post text is unchanged';
end $$;

-- The new shapes: reposts, quote posts, image-only posts, and the rules that
-- keep a row from being nonsense.
select pg_temp.as_user('15550001111');

select pg_temp.expect_ok(
  $$insert into public.public_posts (id, author_phone, author_username, repost_of)
    values ('t_rp','15550001111','alice','t_p1')$$,
  'a plain repost needs no text');

select pg_temp.expect_ok(
  $$insert into public.public_posts (id, author_phone, author_username, body, repost_of)
    values ('t_qp','15550001111','alice','my take','t_p1')$$,
  'a quote post is a repost with text');

select pg_temp.expect_ok(
  $$insert into public.public_posts (id, author_phone, author_username, image_path)
    values ('t_img','15550001111','alice','t_img.jpg')$$,
  'an image-only post needs no text');

select pg_temp.expect_fail(
  $$insert into public.public_posts (id, author_phone, author_username)
    values ('t_empty','15550001111','alice')$$,
  'a post with nothing in it is refused');

select pg_temp.expect_fail(
  $$insert into public.public_posts
      (id, author_phone, author_username, body, reply_to, repost_of)
    values ('t_both','15550001111','alice','x','t_p1','t_p1')$$,
  'a post cannot be both a reply and a repost');

select pg_temp.expect_fail(
  $$insert into public.public_posts (id, author_phone, author_username, body)
    values ('t_long','15550001111','alice', repeat('x', 501))$$,
  'over 500 characters is refused');

do $$ begin
  if (select repost_count from public.public_feed where id='t_p1') <> 2 then
    raise exception 'CHECK FAILED: repost_count is %, expected 2',
      (select repost_count from public.public_feed where id='t_p1');
  end if;
  raise notice '  ok   reposts are counted (quote posts included)';
end $$;

-- Deleting the original takes its reposts: a repost of nothing is not a post.
reset role; set role authenticated; select pg_temp.as_user('15550001111');
select pg_temp.expect_ok($$delete from public.public_posts where id='t_p1'$$,
  'you can delete your own post');
do $$ begin
  if (select count(*) from public.public_feed where id in ('t_rp','t_qp')) <> 0 then
    raise exception 'CHECK FAILED: a repost outlived the post it repeats';
  end if;
  raise notice '  ok   deleting a post removes its reposts';
end $$;

-- The image bucket is public (these are attachments on public posts) and
-- clients may add but never replace.
do $$ begin
  if not (select public from storage.buckets where id='public-media') then
    raise exception 'CHECK FAILED: public-media should be a public bucket';
  end if;
  raise notice '  ok   the image bucket is public, as a public feed implies';
end $$;

-- Push tokens. The app upserts its token on every launch, so the second
-- launch is the one that matters — and it is the one that was failing.
reset role; set role authenticated; select pg_temp.as_user('15550001111');

select pg_temp.expect_ok(
  $$insert into public.push_tokens (phone, token, platform)
    values ('15550001111','apns-aaa','ios')
    on conflict (phone) do update set token = excluded.token$$,
  'you can register a push token');
select pg_temp.expect_ok(
  $$insert into public.push_tokens (phone, token, platform)
    values ('15550001111','apns-bbb','ios')
    on conflict (phone) do update set token = excluded.token$$,
  'and register it again on the next launch');
select pg_temp.expect_fail(
  $$insert into public.push_tokens (phone, token, platform)
    values ('15550002222','apns-ccc','ios')$$,
  'you cannot register a token for somebody else');

-- Your own row, and only your own.
do $$ begin
  if (select count(*) from public.push_tokens) <> 1 then
    raise exception 'CHECK FAILED: your own token row should be visible';
  end if;
  raise notice '  ok   your own row is visible, which is what the upsert needs';
end $$;
reset role;
insert into public.push_tokens (phone, token) values ('15550007777','apns-ddd')
  on conflict (phone) do nothing;
set role authenticated; select pg_temp.as_user('15550001111');
do $$ begin
  if (select count(*) from public.push_tokens
        where phone = '15550007777') <> 0 then
    raise exception 'SECURITY CHECK FAILED: somebody else''s token row is visible';
  end if;
  raise notice '  ok   and nobody else''s is';
end $$;

-- Polls. Everything that makes a vote a vote is enforced in the database, so
-- a modified client gains nothing by asking differently.
reset role; set role authenticated; select pg_temp.as_user('15550001111');

select pg_temp.expect_ok(
  $$insert into public.public_posts
      (id, author_phone, author_username, body, poll_options, poll_closes_at)
    values ('t_poll','15550001111','alice','Tabs or spaces?',
            array['Tabs','Spaces'], now() + interval '1 day')$$,
  'you can post a poll');

select pg_temp.expect_fail(
  $$insert into public.public_posts
      (id, author_phone, author_username, body, poll_options, poll_closes_at)
    values ('t_p1o','15550001111','alice','One answer?', array['Yes'],
            now() + interval '1 day')$$,
  'a poll with one answer is refused');

select pg_temp.expect_fail(
  $$insert into public.public_posts
      (id, author_phone, author_username, body, poll_options, poll_closes_at)
    values ('t_p5o','15550001111','alice','Five?',
            array['a','b','c','d','e'], now() + interval '1 day')$$,
  'a poll with five answers is refused');

select pg_temp.expect_fail(
  $$insert into public.public_posts
      (id, author_phone, author_username, body, poll_options, poll_closes_at)
    values ('t_pblank','15550001111','alice','Blank?', array['Yes','  '],
            now() + interval '1 day')$$,
  'a blank answer is refused');

select pg_temp.expect_fail(
  $$insert into public.public_posts
      (id, author_phone, author_username, body, poll_options)
    values ('t_pnoend','15550001111','alice','Forever?', array['Yes','No'])$$,
  'a poll that never closes is refused');

select pg_temp.expect_fail(
  $$insert into public.public_posts
      (id, author_phone, author_username, poll_options, poll_closes_at)
    values ('t_pnoq','15550001111','alice', array['Yes','No'],
            now() + interval '1 day')$$,
  'a poll with no question is refused');

select pg_temp.expect_fail(
  $$insert into public.public_posts
      (id, author_phone, author_username, body, repost_of, poll_options,
       poll_closes_at)
    values ('t_prp','15550001111','alice','Q', 't_poll', array['Yes','No'],
            now() + interval '1 day')$$,
  'a repost cannot also be a poll');

-- Voting.
select pg_temp.as_user('15550002222');
-- Before any vote by this account lands, or the primary key would be what
-- refuses this and the bound in the policy would go untested.
select pg_temp.expect_fail(
  $$insert into public.public_post_votes (post_id, voter_phone, choice)
    values ('t_poll','15550002222',3)$$,
  'you cannot pick an answer the poll does not have');
select pg_temp.expect_ok(
  $$insert into public.public_post_votes (post_id, voter_phone, choice)
    values ('t_poll','15550002222',1)$$,
  'you can vote');
select pg_temp.expect_fail(
  $$insert into public.public_post_votes (post_id, voter_phone, choice)
    values ('t_poll','15550002222',0)$$,
  'you cannot vote twice');
select pg_temp.expect_fail(
  $$insert into public.public_post_votes (post_id, voter_phone, choice)
    values ('t_poll','15550001111',0)$$,
  'you cannot vote as somebody else');
select pg_temp.expect_fail(
  $$update public.public_post_votes set choice = 0 where post_id = 't_poll'$$,
  'a vote cannot be changed');
select pg_temp.expect_fail(
  $$delete from public.public_post_votes where post_id = 't_poll'$$,
  'a vote cannot be taken back');
select pg_temp.expect_fail(
  $$select voter_phone from public.public_post_votes$$,
  'a client cannot read who voted');

-- A post that is not a poll cannot be voted on, and a closed one cannot
-- either. Both are refusals the app must not be trusted with.
select pg_temp.as_user('15550001111');
select pg_temp.expect_fail(
  $$insert into public.public_post_votes (post_id, voter_phone, choice)
    values ('t_p4','15550001111',0)$$,
  'a post that is not a poll cannot be voted on');
reset role;
insert into public.public_posts
    (id, author_phone, author_username, body, poll_options, poll_closes_at)
  values ('t_shut','15550001111','alice','Over?', array['Yes','No'],
          now() - interval '1 minute');
set role authenticated; select pg_temp.as_user('15550002222');
select pg_temp.expect_fail(
  $$insert into public.public_post_votes (post_id, voter_phone, choice)
    values ('t_shut','15550002222',0)$$,
  'a closed poll takes no more votes');

-- The tally is true even though nobody can read the rows behind it.
reset role;
insert into public.public_post_votes (post_id, voter_phone, choice) values
  ('t_poll','15550003333',1), ('t_poll','15550009999',0);
set role authenticated; select pg_temp.as_user('15550002222');
do $$
declare got int[];
begin
  select poll_votes into got from public.public_feed where id = 't_poll';
  if got <> array[1,2] then
    raise exception 'CHECK FAILED: tally is %, expected {1,2}', got;
  end if;
  raise notice '  ok   the tally counts every vote, readable by nobody';
end $$;

do $$ begin
  if (select poll_votes from public.public_feed where id = 't_p4')
       <> '{}'::int[] then
    raise exception 'CHECK FAILED: a post with no poll has a tally';
  end if;
  raise notice '  ok   a post that is not a poll has no tally';
end $$;

-- Payment controls. The whole point of storing these server-side is that the
-- account cannot change them by talking to Postgres directly — only the Edge
-- Functions, on the service-role key, may. RLS is on with no policies, so
-- every one of these is refused or silently matches nothing.
reset role;
insert into public.payment_settings (phone, daily_send_limit_cents, paused)
  values ('15550001111', 10000, false)
  on conflict (phone) do update set daily_send_limit_cents = 10000;
insert into public.payment_blocks (phone, blocked_phone)
  values ('15550001111', '15550002222') on conflict do nothing;
set role authenticated;
select pg_temp.as_user('15550001111');

do $$ begin
  if (select count(*) from public.payment_settings) <> 0 then
    raise exception 'SECURITY CHECK FAILED: a client can read payment settings';
  end if;
  raise notice '  ok   a client cannot read payment settings';
end $$;

update public.payment_settings set daily_send_limit_cents = 200000
  where phone = '15550001111';
do $$ begin
  if (select daily_send_limit_cents from public.payment_settings) is not null then
    raise exception 'SECURITY CHECK FAILED: a client raised its own send limit';
  end if;
  raise notice '  ok   a client cannot raise its own send limit';
end $$;

update public.payment_settings set paused = false where phone = '15550001111';
delete from public.payment_blocks where phone = '15550001111';
reset role;
do $$ begin
  if (select count(*) from public.payment_blocks
      where phone='15550001111') <> 1 then
    raise exception 'SECURITY CHECK FAILED: a client unblocked itself';
  end if;
  raise notice '  ok   a client cannot unblock itself';
end $$;

-- The upgrade path put the v2 columns back. Without these the delayed-raise
-- rule has nowhere to store what is waiting, and every raise would apply at
-- once — silently, because the function reads null and carries on.
do $$
declare missing text;
begin
  select string_agg(c, ', ') into missing from unnest(array[
    'paused', 'max_send_cents',
    'pending_daily_send_limit_cents', 'pending_daily_effective_at',
    'pending_max_send_cents', 'pending_max_effective_at']) c
  where not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='payment_settings'
      and column_name = c);
  if missing is not null then
    raise exception 'CHECK FAILED: payment_settings is missing %', missing;
  end if;
  raise notice '  ok   an existing project gains the new limit columns';
end $$;
set role authenticated;
select pg_temp.as_user('15550001111');

-- The directory hides a banned account too (platform_moderation.sql).
reset role;
insert into public.usernames (phone, username, name)
  values ('15550009999','banned','Banned') on conflict (phone) do nothing;
set role authenticated;
select pg_temp.as_user('15550001111');
do $$ begin
  if (select count(*) from public.usernames where username='banned') <> 0 then
    raise exception 'SECURITY CHECK FAILED: a banned account is still in the directory';
  end if;
  raise notice '  ok   a banned account leaves the directory';
end $$;

-- Numberless directory (directory_numberless.sql): the RPCs are anon's only
-- door, and the claim only ever opens account-code rows.
reset role;
set role anon;
do $$ begin
  if not (select public.claim_numberless('001234567890', 'ghosty', 'Ghost')) then
    raise exception 'CHECK FAILED: a numberless account cannot claim its handle';
  end if;
  if (select public.claim_numberless('15550001111', 'realphone', 'X')) then
    raise exception 'SECURITY CHECK FAILED: anon claimed a REAL number''s directory row';
  end if;
  if (select public.claim_numberless('001234567890', 'ghosty2', 'G')) then
    raise exception 'SECURITY CHECK FAILED: a handle was changed with no proof the code is yours';
  end if;
  if (select public.claim_numberless('009999999999', 'ghosty', 'Z')) then
    raise exception 'SECURITY CHECK FAILED: a taken handle was claimed by a second code';
  end if;
  if not exists (select 1 from public.find_people('gho') where phone = '001234567890') then
    raise exception 'CHECK FAILED: anon username search finds nothing';
  end if;
  raise notice '  ok   numberless accounts claim and search through the RPCs alone';
end $$;
reset role;
SQL

DB=okaycheck
su pg -c "PATH=$PGBIN:\$PATH createdb -h $RUN -p $PORT $DB"
# Status first, output second — for the third time in this file, piping psql
# into grep hands the pipeline grep's exit code and turns a failure into a pass.
apply() {
  set +e
  su pg -c "PATH=$PGBIN:\$PATH psql -h $RUN -p $PORT -d $DB -v ON_ERROR_STOP=1 -q -f $1" \
    >"$WORK/apply.txt" 2>&1
  rc=$?
  set -e
  grep -vE "NOTICE:" "$WORK/apply.txt" | grep -v "^$" || true
  return $rc
}

echo "postgres $(su pg -c "PATH=$PGBIN:\$PATH psql -h $RUN -p $PORT -d $DB -tAc 'show server_version'")"
for f in "$WORK/harness.sql" supabase/schema.sql docs/platform_moderation.sql docs/public_feed.sql docs/payment_controls.sql docs/directory_numberless.sql; do
  if apply "$f"; then
    echo "  applied $(basename "$f")"
  else
    echo "  FAILED  $(basename "$f")"; exit 1
  fi
done

# UPGRADING A PROJECT THAT ALREADY RAN AN EARLIER VERSION
#
# Every file here claims to be safe to run twice, and a fresh database cannot
# check that claim: it never holds the *older* shape there is to migrate from.
# A bug reached the dashboard for exactly this reason —
#
#   42P16: cannot change name of view column "created_at" to "repost_of"
#
# — because `create or replace view` may only append columns to the end, and a
# first run has no previous view to collide with. Nothing here could see it.
#
# So put the old shape back: v1's table columns, v1's body CHECK, v1's view with
# its own column order. Then run the file again and require it to succeed. The
# assertions below then run against the *migrated* database, so the upgrade path
# has to arrive at the same guarantees the fresh one does.
cat >"$WORK/v1shape.sql" <<'SQL'
drop view if exists public.public_feed;
drop table if exists public.public_post_votes;
alter table public.public_posts drop constraint if exists public_posts_poll_shape;
alter table public.public_posts drop column if exists poll_options cascade;
alter table public.public_posts drop column if exists poll_closes_at cascade;
alter table public.public_posts drop column if exists repost_of cascade;
alter table public.public_posts drop column if exists image_path cascade;
alter table public.public_posts drop constraint if exists public_posts_not_empty;
alter table public.public_posts drop constraint if exists public_posts_reply_xor_repost;
alter table public.public_posts drop constraint if exists public_posts_body_check;
alter table public.public_posts
  add constraint public_posts_body_check check (char_length(body) between 1 and 500);
create view public.public_feed with (security_invoker = on) as
select p.id, p.author_username, p.author_name, p.author_verified, p.body,
       p.reply_to, p.created_at,
       public.public_post_like_count(p.id)  as like_count,
       public.public_post_reply_count(p.id) as reply_count
from public.public_posts p;
grant select on public.public_feed to anon, authenticated;

-- payment_controls.sql v1: the limits table before pausing, per-transfer caps
-- and delayed raises existed. Its ALTERs are the upgrade path, and a fresh
-- database never runs them.
alter table public.payment_settings drop column if exists paused;
alter table public.payment_settings drop column if exists max_send_cents;
alter table public.payment_settings
  drop column if exists pending_daily_send_limit_cents;
alter table public.payment_settings
  drop column if exists pending_daily_effective_at;
alter table public.payment_settings drop column if exists pending_max_send_cents;
alter table public.payment_settings drop column if exists pending_max_effective_at;
SQL

if apply "$WORK/v1shape.sql"; then
  echo "  rolled back to the previous shape"
else
  echo "  FAILED  could not rebuild the previous shape"; exit 1
fi

for f in supabase/schema.sql docs/platform_moderation.sql docs/public_feed.sql docs/payment_controls.sql docs/directory_numberless.sql; do
  if apply "$f"; then
    echo "  re-applied $(basename "$f")"
  else
    echo "  FAILED  $(basename "$f") is not safe to run twice"; exit 1
  fi
done

# Status first, output second: piping psql into grep hands the pipeline grep's
# exit code, and this script would print "passed" over a failed assertion.
set +e
su pg -c "PATH=$PGBIN:\$PATH psql -h $RUN -p $PORT -d $DB -v ON_ERROR_STOP=1 -q -f $WORK/assert.sql" \
  >"$WORK/out.txt" 2>&1
status=$?
set -e
grep -E "NOTICE:|ERROR:" "$WORK/out.txt" | sed -E 's/^.*(NOTICE|ERROR):  ?//' || true
if [ "$status" -ne 0 ]; then
  echo "SQL checks FAILED"
  exit 1
fi
echo "SQL checks passed"
