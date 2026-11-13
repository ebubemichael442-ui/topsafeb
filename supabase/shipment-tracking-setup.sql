-- TopSafeB fictional shipment tracking simulator
-- Run this file in the Supabase SQL Editor.
create extension if not exists pgcrypto;

create table if not exists public.shipment_tracking (
  id uuid primary key default gen_random_uuid(),
  tracking_code text not null unique,
  owner_id uuid not null references auth.users(id) on delete cascade,
  sender_name text not null,
  recipient_name text not null,
  origin_address text not null,
  destination_address text not null,
  parcel_description text not null default '',
  status text not null default 'Shipment Created'
    check (status in ('Shipment Created','Processing','In Transit','Arrived at Facility','Out for Delivery','Delivered','Delivery Exception')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.shipment_tracking_updates (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references public.shipment_tracking(id) on delete cascade,
  owner_id uuid not null references auth.users(id) on delete cascade,
  status text not null,
  location text not null default '',
  note text not null default '',
  created_at timestamptz not null default now()
);

create index if not exists shipment_tracking_owner_idx on public.shipment_tracking(owner_id, created_at desc);
create index if not exists shipment_tracking_updates_shipment_idx on public.shipment_tracking_updates(shipment_id, created_at desc);

alter table public.shipment_tracking enable row level security;
alter table public.shipment_tracking_updates enable row level security;

drop policy if exists "Admins manage their tracking records" on public.shipment_tracking;
create policy "Admins manage their tracking records"
on public.shipment_tracking for all to authenticated
using (owner_id = auth.uid() and exists (select 1 from public.admin_users a where a.user_id = auth.uid()))
with check (owner_id = auth.uid() and exists (select 1 from public.admin_users a where a.user_id = auth.uid()));

drop policy if exists "Admins manage tracking updates" on public.shipment_tracking_updates;
create policy "Admins manage tracking updates"
on public.shipment_tracking_updates for all to authenticated
using (owner_id = auth.uid() and exists (select 1 from public.admin_users a where a.user_id = auth.uid()))
with check (owner_id = auth.uid() and exists (select 1 from public.admin_users a where a.user_id = auth.uid()));

create or replace function public.get_public_tracking(p_tracking_code text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'tracking_code', s.tracking_code,
    'sender_name', s.sender_name,
    'recipient_name', s.recipient_name,
    'origin_address', s.origin_address,
    'destination_address', s.destination_address,
    'parcel_description', s.parcel_description,
    'status', s.status,
    'created_at', s.created_at,
    'updated_at', s.updated_at,
    'updates', coalesce((
      select jsonb_agg(jsonb_build_object(
        'status', u.status,
        'location', u.location,
        'note', u.note,
        'created_at', u.created_at
      ) order by u.created_at desc)
      from public.shipment_tracking_updates u
      where u.shipment_id = s.id
    ), '[]'::jsonb),
    'notice', 'Fictional tracking simulator record; not a live courier shipment.'
  )
  from public.shipment_tracking s
  where upper(trim(s.tracking_code)) = upper(trim(p_tracking_code))
  limit 1;
$$;

revoke all on function public.get_public_tracking(text) from public;
grant execute on function public.get_public_tracking(text) to anon, authenticated;
