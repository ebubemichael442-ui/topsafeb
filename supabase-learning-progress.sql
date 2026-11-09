-- TopSafeB: account-based lesson progress
-- Run this script in Supabase SQL Editor.

create table if not exists public.learning_progress (
  user_id uuid primary key references auth.users(id) on delete cascade,
  completed_lessons jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now(),
  constraint learning_progress_completed_lessons_is_array
    check (jsonb_typeof(completed_lessons) = 'array')
);

alter table public.learning_progress
add column if not exists completed_at timestamptz;

alter table public.learning_progress enable row level security;

drop policy if exists "Customers can view own learning progress" on public.learning_progress;
create policy "Customers can view own learning progress"
on public.learning_progress for select to authenticated
using (auth.uid() = user_id);

drop policy if exists "Customers can create own learning progress" on public.learning_progress;
create policy "Customers can create own learning progress"
on public.learning_progress for insert to authenticated
with check (auth.uid() = user_id);

drop policy if exists "Customers can update own learning progress" on public.learning_progress;
create policy "Customers can update own learning progress"
on public.learning_progress for update to authenticated
using (auth.uid() = user_id)
with check (auth.uid() = user_id);

drop policy if exists "Admins can view all learning progress" on public.learning_progress;
create policy "Admins can view all learning progress"
on public.learning_progress for select to authenticated
using (
  exists (
    select 1 from public.admin_users
    where admin_users.user_id = auth.uid()
  )
);
