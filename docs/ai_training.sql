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
