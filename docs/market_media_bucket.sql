-- Storage bucket for sealed marketplace listing videos.
-- ============================================================================
-- Run this ONCE in the Supabase dashboard (SQL Editor → New query → Run).
--
-- WHY A BUCKET. A video cannot ride the message relay: one broadcast caps out
-- around a quarter megabyte and even a short clip is tens of that, each chunk
-- a mailbox row per offline member, one lost chunk a broken video. Videos are
-- also the first marketplace media that costs real money to host, which is
-- why uploading them requires the cloud storage subscription in the app.
--
-- WHAT'S IN IT. One object per listing, at <serverId>/<listingId>.sealed.
-- The bytes are AES-256-GCM ciphertext sealed with the server's shared key —
-- the same key that seals the server's relay traffic — so only members of
-- that server (the listing's entire audience) can play the video. The bucket
-- operator sees ciphertext. Plaintext media must never be stored here.

-- Private bucket; 24 MB per object comfortably covers a sealed 12 MB video
-- (base64 + encryption inflate ~4/3) and stops runaways.
insert into storage.buckets (id, name, public, file_size_limit)
values ('market-media', 'market-media', false, 25165824)
on conflict (id) do update
  set public = false,
      file_size_limit = 25165824;

-- Access model, matching the relay itself: the object path contains the
-- server id, which is only known to members (it arrives inside the E2E
-- encrypted invite), and the contents are sealed with the server key anyway.
-- With REQUIRE_OTP off there is no verified caller for RLS to bind to; the
-- seal is the real protection, exactly as it is for relay traffic.
drop policy if exists market_media_read on storage.objects;
create policy market_media_read on storage.objects
  for select to anon, authenticated
  using (bucket_id = 'market-media');

drop policy if exists market_media_insert on storage.objects;
create policy market_media_insert on storage.objects
  for insert to anon, authenticated
  with check (bucket_id = 'market-media');

drop policy if exists market_media_update on storage.objects;
create policy market_media_update on storage.objects
  for update to anon, authenticated
  using (bucket_id = 'market-media');

-- Sellers remove their video when the listing goes.
drop policy if exists market_media_delete on storage.objects;
create policy market_media_delete on storage.objects
  for delete to anon, authenticated
  using (bucket_id = 'market-media');
