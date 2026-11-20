-- TopSafeB Insight Hub: privacy-minimised customer and demo activity
-- Additive migration. Does not change balances, transfers, support messages or page-view records.
-- Run once in the existing TopSafeB Supabase SQL Editor.

create table if not exists public.insight_hub_activity_events (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  event_type text not null check (event_type in (
    'signup','login','logout','demo_transfer','demo_topup_request'
  )),
  created_at timestamptz not null default now()
);

create index if not exists insight_hub_activity_events_created_idx
  on public.insight_hub_activity_events (created_at desc);
create index if not exists insight_hub_activity_events_type_created_idx
  on public.insight_hub_activity_events (event_type, created_at desc);

alter table public.insight_hub_activity_events enable row level security;

drop policy if exists "Customers can record their own limited activity" on public.insight_hub_activity_events;
create policy "Customers can record their own limited activity"
on public.insight_hub_activity_events
for insert to authenticated
with check (
  user_id = auth.uid()
  and event_type in ('login','logout','demo_transfer','demo_topup_request')
);

drop policy if exists "TopSafeB admins can read activity events" on public.insight_hub_activity_events;
create policy "TopSafeB admins can read activity events"
on public.insight_hub_activity_events
for select to authenticated
using (
  exists (
    select 1 from public.admin_users a
    where a.user_id = auth.uid()
  )
);

revoke all on public.insight_hub_activity_events from public;
grant insert on public.insight_hub_activity_events to authenticated;
grant select on public.insight_hub_activity_events to authenticated;


-- Keep one signup event per customer, including customers who registered before
-- this tracking feature was installed. This is safe to rerun.
create unique index if not exists insight_hub_one_signup_per_customer
  on public.insight_hub_activity_events (user_id)
  where event_type = 'signup';

-- Record signups without storing email addresses, names, passwords or profile fields.
create or replace function public.insight_hub_record_customer_signup()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.insight_hub_activity_events(user_id, event_type)
  values (new.id, 'signup')
  on conflict do nothing;
  return new;
end;
$$;

drop trigger if exists insight_hub_customer_signup_event on auth.users;
create trigger insight_hub_customer_signup_event
after insert on auth.users
for each row execute function public.insight_hub_record_customer_signup();

revoke all on function public.insight_hub_record_customer_signup() from public;


-- Capture successful simulated transactions and top-up requests server-side.
create or replace function public.insight_hub_record_demo_transaction()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.action = 'transfer' then
    insert into public.insight_hub_activity_events(user_id,event_type)
    values(new.user_id,'demo_transfer');
  end if;
  return new;
end;
$$;

drop trigger if exists insight_hub_demo_transaction_event on public.demo_transactions;
create trigger insight_hub_demo_transaction_event
after insert on public.demo_transactions
for each row execute function public.insight_hub_record_demo_transaction();

create or replace function public.insight_hub_record_demo_topup_request()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.insight_hub_activity_events(user_id,event_type)
  values(new.user_id,'demo_topup_request');
  return new;
end;
$$;

drop trigger if exists insight_hub_demo_topup_request_event on public.demo_topup_requests;
create trigger insight_hub_demo_topup_request_event
after insert on public.demo_topup_requests
for each row execute function public.insight_hub_record_demo_topup_request();

revoke all on function public.insight_hub_record_demo_transaction() from public;
revoke all on function public.insight_hub_record_demo_topup_request() from public;

-- Backfill historical customer sign-ups once, using account creation timestamps.
insert into public.insight_hub_activity_events(user_id, event_type, created_at)
select u.id, 'signup', u.created_at
from auth.users u
where not exists (
  select 1 from public.insight_hub_activity_events e
  where e.user_id = u.id and e.event_type = 'signup'
)
on conflict do nothing;
