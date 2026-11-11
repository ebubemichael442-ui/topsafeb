-- TopSafeB private owner activity log
-- Run this once in Supabase SQL Editor. This records owner actions only; it does not move funds.

create table if not exists public.owner_activity_logs (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid not null references auth.users(id),
  target_user_id uuid references auth.users(id) on delete set null,
  action text not null check (length(action) between 1 and 100),
  details text not null default '',
  created_at timestamptz not null default now()
);

create index if not exists owner_activity_logs_created_idx
  on public.owner_activity_logs(created_at desc);

alter table public.owner_activity_logs enable row level security;

drop policy if exists "Admins can read owner activity log" on public.owner_activity_logs;
create policy "Admins can read owner activity log"
on public.owner_activity_logs for select to authenticated
using (exists (
  select 1 from public.admin_users a where a.user_id = auth.uid()
));

create or replace function public.admin_record_owner_activity(
  p_action text,
  p_target_user_id uuid default null,
  p_details text default ''
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if auth.uid() is null or not exists (
    select 1 from public.admin_users a where a.user_id = auth.uid()
  ) then
    raise exception 'Administrator access required';
  end if;
  if p_action is null or length(trim(p_action)) < 1 or length(p_action) > 100 then
    raise exception 'Enter a valid activity action';
  end if;
  insert into public.owner_activity_logs(actor_id,target_user_id,action,details)
  values(auth.uid(),p_target_user_id,left(trim(p_action),100),left(coalesce(p_details,''),500))
  returning id into v_id;
  return v_id;
end;
$$;

revoke all on function public.admin_record_owner_activity(text,uuid,text) from public;
grant execute on function public.admin_record_owner_activity(text,uuid,text) to authenticated;
