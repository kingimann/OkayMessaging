-- Okay Messaging — Supabase schema
-- Run this in your Supabase project's SQL editor (Dashboard → SQL → New query).
-- It creates the tables, row-level security policies, and realtime config the
-- app needs. Safe to re-run.

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  name text not null,
  about text default 'Hey there! I am using Okay Messaging.',
  avatar_color text default '#25D366',
  phone text default '',
  is_online boolean default false,
  updated_at timestamptz default now()
);

create table if not exists public.conversations (
  id uuid primary key default gen_random_uuid(),
  is_group boolean not null default false,
  name text,
  created_at timestamptz default now()
);

create table if not exists public.conversation_members (
  conversation_id uuid references public.conversations (id) on delete cascade,
  user_id uuid references public.profiles (id) on delete cascade,
  primary key (conversation_id, user_id)
);

create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid references public.conversations (id) on delete cascade,
  sender_id uuid references public.profiles (id) on delete cascade,
  body text default '',
  is_image boolean default false,
  image_url text,
  created_at timestamptz default now()
);

create index if not exists messages_conversation_idx
  on public.messages (conversation_id, created_at);

-- ---------------------------------------------------------------------------
-- Helper: is the current user a member of a conversation?
-- (SECURITY DEFINER avoids recursive RLS checks on conversation_members.)
-- ---------------------------------------------------------------------------

create or replace function public.is_member(conv uuid)
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.conversation_members m
    where m.conversation_id = conv and m.user_id = auth.uid()
  );
$$;

-- ---------------------------------------------------------------------------
-- Row-level security
-- ---------------------------------------------------------------------------

alter table public.profiles enable row level security;
alter table public.conversations enable row level security;
alter table public.conversation_members enable row level security;
alter table public.messages enable row level security;

-- Profiles: anyone signed in can read (to start chats); you edit only your own.
drop policy if exists profiles_read on public.profiles;
create policy profiles_read on public.profiles
  for select using (auth.role() = 'authenticated');

drop policy if exists profiles_upsert on public.profiles;
create policy profiles_upsert on public.profiles
  for insert with check (auth.uid() = id);

drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles
  for update using (auth.uid() = id);

-- Conversations: members can read; any authenticated user can create one.
drop policy if exists conversations_read on public.conversations;
create policy conversations_read on public.conversations
  for select using (public.is_member(id));

drop policy if exists conversations_insert on public.conversations;
create policy conversations_insert on public.conversations
  for insert with check (auth.role() = 'authenticated');

-- Membership: you can read rows for conversations you belong to, and add
-- members to a conversation you're in (or add yourself).
drop policy if exists members_read on public.conversation_members;
create policy members_read on public.conversation_members
  for select using (public.is_member(conversation_id) or user_id = auth.uid());

drop policy if exists members_insert on public.conversation_members;
create policy members_insert on public.conversation_members
  for insert with check (user_id = auth.uid() or public.is_member(conversation_id));

-- Messages: readable by conversation members; you can send as yourself.
drop policy if exists messages_read on public.messages;
create policy messages_read on public.messages
  for select using (public.is_member(conversation_id));

drop policy if exists messages_insert on public.messages;
create policy messages_insert on public.messages
  for insert with check (
    sender_id = auth.uid() and public.is_member(conversation_id)
  );

-- ---------------------------------------------------------------------------
-- Realtime: broadcast message inserts to subscribed clients.
-- ---------------------------------------------------------------------------

alter publication supabase_realtime add table public.messages;

-- ---------------------------------------------------------------------------
-- Storage bucket for shared photos (public read).
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public)
values ('media', 'media', true)
on conflict (id) do nothing;

drop policy if exists media_read on storage.objects;
create policy media_read on storage.objects
  for select using (bucket_id = 'media');

drop policy if exists media_write on storage.objects;
create policy media_write on storage.objects
  for insert with check (bucket_id = 'media' and auth.role() = 'authenticated');
