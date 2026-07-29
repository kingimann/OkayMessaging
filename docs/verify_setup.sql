-- Did the setup SQL actually land?
-- ============================================================================
-- Paste into the Supabase SQL editor and Run. Reads nothing but catalog
-- metadata and your own role row — it changes nothing, so it is safe to run
-- any time.
--
-- Every row should read OK. An "MISSING" row names the file to run.

with checks(item, ok, fix) as (
  values
    -- docs/payment_controls.sql
    ('payment_settings table',
     to_regclass('public.payment_settings') is not null,
     'run docs/payment_controls.sql'),
    ('payment_blocks table',
     to_regclass('public.payment_blocks') is not null,
     'run docs/payment_controls.sql'),

    -- docs/identity_directory_badge.sql
    ('usernames.verified column',
     exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'usernames'
                and column_name = 'verified'),
     'run docs/identity_directory_badge.sql'),

    -- docs/directory_privacy.sql
    ('usernames.find_by_username column',
     exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'usernames'
                and column_name = 'find_by_username'),
     'run docs/directory_privacy.sql'),
    ('usernames.find_by_phone column',
     exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'usernames'
                and column_name = 'find_by_phone'),
     'run docs/directory_privacy.sql'),

    -- docs/market_media_bucket.sql
    ('market-media storage bucket',
     exists (select 1 from storage.buckets where id = 'market-media'),
     'run docs/market_media_bucket.sql'),

    -- docs/platform_moderation.sql
    ('platform_roles table',
     to_regclass('public.platform_roles') is not null,
     'run docs/platform_moderation.sql'),
    ('account_sanctions table',
     to_regclass('public.account_sanctions') is not null,
     'run docs/platform_moderation.sql'),
    ('moderation_log table',
     to_regclass('public.moderation_log') is not null,
     'run docs/platform_moderation.sql'),
    ('moderation_reports table',
     to_regclass('public.moderation_reports') is not null,
     'run docs/platform_moderation.sql'),
    ('is_locked_out() function',
     exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'is_locked_out'),
     'run docs/platform_moderation.sql'),

    -- THE ENFORCEMENT. This is the row that matters most: without it a ban
    -- shows in the app while the database keeps handing the account out in
    -- search. Re-running supabase/schema.sql silently resets it.
    ('ban enforcement live on usernames_read',
     exists (select 1 from pg_policies
              where schemaname = 'public' and tablename = 'usernames'
                and policyname = 'usernames_read'
                and qual like '%is_locked_out%'),
     'run docs/platform_moderation.sql AFTER supabase/schema.sql'),

    -- Roles are granted by SQL and nothing else, so this is easy to forget.
    ('at least one owner exists',
     exists (select 1 from public.platform_roles where role = 'owner'),
     'uncomment the grant at the end of docs/platform_moderation.sql')
)
select
  case when ok then 'OK      ' else 'MISSING ' end || item as result,
  case when ok then '' else fix end as todo
from checks
order by ok, item;

-- Who holds a platform role, and how their number is stored. The app matches
-- on E.164 digits with no '+' and no spaces, so '+1 555 123 4567' here would
-- never match the caller and the console would stay hidden.
select phone, role, created_at from public.platform_roles order by role;
