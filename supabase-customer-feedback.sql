-- TopSafeB: private customer feedback storage
-- Run this script once in Supabase SQL Editor.

create table if not exists public.customer_feedback (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  customer_name text not null default '',
  customer_email text not null default '',
  rating text not null check (rating in ('Very good','Good','Fair','Needs improvement')),
  message text not null check (char_length(trim(message)) between 1 and 3000),
  status text not null default 'New' check (status in ('New','Reviewed')),
  created_at timestamptz not null default now()
);

alter table public.customer_feedback enable row level security;

drop policy if exists "Customers can submit own feedback" on public.customer_feedback;
create policy "Customers can submit own feedback"
on public.customer_feedback for insert to authenticated
with check (auth.uid() = user_id);

drop policy if exists "Admins can view customer feedback" on public.customer_feedback;
create policy "Admins can view customer feedback"
on public.customer_feedback for select to authenticated
using (
  exists (
    select 1 from public.admin_users
    where admin_users.user_id = auth.uid()
  )
);

drop policy if exists "Admins can update customer feedback status" on public.customer_feedback;
create policy "Admins can update customer feedback status"
on public.customer_feedback for update to authenticated
using (
  exists (
    select 1 from public.admin_users
    where admin_users.user_id = auth.uid()
  )
)
with check (
  exists (
    select 1 from public.admin_users
    where admin_users.user_id = auth.uid()
  )
);
