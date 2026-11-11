-- TopSafeB individual customer dashboard access controls
-- Run once in the Supabase SQL Editor before using the Owner Dashboard controls.

create table if not exists public.customer_access_controls (
  user_id uuid primary key references auth.users(id) on delete cascade,
  is_blocked boolean not null default false,
  reason text not null default '',
  updated_by uuid references auth.users(id),
  updated_at timestamptz not null default now()
);

alter table public.customer_access_controls enable row level security;

drop policy if exists "Admins can read customer access controls" on public.customer_access_controls;
create policy "Admins can read customer access controls"
on public.customer_access_controls for select to authenticated
using (exists (
  select 1 from public.admin_users a where a.user_id = auth.uid()
));

create or replace function public.customer_access_is_blocked()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select c.is_blocked
    from public.customer_access_controls c
    where c.user_id = auth.uid()
  ), false);
$$;

create or replace function public.admin_set_customer_access(
  p_user_id uuid,
  p_is_blocked boolean,
  p_reason text default ''
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not exists (
    select 1 from public.admin_users a where a.user_id = auth.uid()
  ) then
    raise exception 'Administrator access required';
  end if;

  if p_user_id is null then
    raise exception 'A customer account is required';
  end if;

  if exists (select 1 from public.admin_users a where a.user_id = p_user_id) then
    raise exception 'Administrator accounts cannot be blocked from the customer dashboard';
  end if;

  insert into public.customer_access_controls(user_id,is_blocked,reason,updated_by,updated_at)
  values(p_user_id,coalesce(p_is_blocked,false),left(coalesce(p_reason,''),300),auth.uid(),now())
  on conflict (user_id) do update
    set is_blocked = excluded.is_blocked,
        reason = excluded.reason,
        updated_by = excluded.updated_by,
        updated_at = now();

  return coalesce(p_is_blocked,false);
end;
$$;

revoke all on function public.customer_access_is_blocked() from public;
grant execute on function public.customer_access_is_blocked() to authenticated;
revoke all on function public.admin_set_customer_access(uuid,boolean,text) from public;
grant execute on function public.admin_set_customer_access(uuid,boolean,text) to authenticated;
