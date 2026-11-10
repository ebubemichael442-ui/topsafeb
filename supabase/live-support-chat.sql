-- TopSafeB private live support chat
-- Run this entire file once in Supabase SQL Editor.
create table if not exists public.support_messages (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references auth.users(id) on delete cascade,
 sender_id uuid not null references auth.users(id) on delete cascade,
 sender_role text not null check (sender_role in ('customer','owner')),
 message text not null check (char_length(trim(message)) between 1 and 2000),
 created_at timestamptz not null default now()
);
create index if not exists support_messages_user_created_idx on public.support_messages(user_id, created_at);
alter table public.support_messages enable row level security;
drop policy if exists "Customers and owners can read support messages" on public.support_messages;
create policy "Customers and owners can read support messages" on public.support_messages
 for select to authenticated using (
  user_id = auth.uid()
  or exists (select 1 from public.admin_users au where au.user_id = auth.uid())
 );
drop policy if exists "Customers and owners can send support messages" on public.support_messages;
create policy "Customers and owners can send support messages" on public.support_messages
 for insert to authenticated with check (
  sender_id = auth.uid()
  and (
   (sender_role = 'customer' and user_id = auth.uid())
   or
   (sender_role = 'owner' and exists (select 1 from public.admin_users au where au.user_id = auth.uid()))
  )
 );
revoke all on public.support_messages from anon;
grant select, insert on public.support_messages to authenticated;
