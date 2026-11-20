-- TopSafeB Package Tracking Centre
-- Isolated, additive schema. Does not modify customer accounts, demo balances,
-- transfers, support messages, Insight Hub tables, or page-view history.

create table if not exists public.package_shipments (
  id uuid primary key default gen_random_uuid(),
  tracking_number text not null unique check (tracking_number ~ '^TSB-[A-Z0-9]{8,16}$'),
  sender_name text not null check (length(trim(sender_name)) between 2 and 120),
  recipient_name text not null check (length(trim(recipient_name)) between 2 and 120),
  origin text not null check (length(trim(origin)) between 2 and 160),
  destination text not null check (length(trim(destination)) between 2 and 160),
  status text not null default 'Pending' check (status in ('Pending','Dispatched','In Transit','Out for Delivery','Delivered','Exception','Cancelled')),
  dispatch_date date,
  estimated_delivery_date date,
  delivered_at timestamptz,
  internal_notes text not null default '',
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists package_shipments_tracking_idx on public.package_shipments(tracking_number);
create index if not exists package_shipments_created_idx on public.package_shipments(created_at desc);

create table if not exists public.package_tracking_events (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references public.package_shipments(id) on delete cascade,
  status text not null check (status in ('Pending','Dispatched','In Transit','Out for Delivery','Delivered','Exception','Cancelled')),
  location text not null default '',
  public_note text not null default '',
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);

create index if not exists package_tracking_events_shipment_idx
  on public.package_tracking_events(shipment_id, created_at desc);

alter table public.package_shipments enable row level security;
alter table public.package_tracking_events enable row level security;

drop policy if exists "Package managers can manage shipments" on public.package_shipments;
create policy "Package managers can manage shipments"
on public.package_shipments for all to authenticated
using (exists (select 1 from public.admin_users a where a.user_id = auth.uid()))
with check (
  exists (select 1 from public.admin_users a where a.user_id = auth.uid())
  and created_by = auth.uid()
);

drop policy if exists "Package managers can manage tracking events" on public.package_tracking_events;
create policy "Package managers can manage tracking events"
on public.package_tracking_events for all to authenticated
using (exists (select 1 from public.admin_users a where a.user_id = auth.uid()))
with check (
  exists (select 1 from public.admin_users a where a.user_id = auth.uid())
  and created_by = auth.uid()
);

revoke all on public.package_shipments from anon, public;
revoke all on public.package_tracking_events from anon, public;
grant select, insert, update, delete on public.package_shipments to authenticated;
grant select, insert, update, delete on public.package_tracking_events to authenticated;

-- Public lookup returns only shipment status, route labels, dates and public event notes.
-- Sender/recipient names and internal notes are never returned to anonymous visitors.
create or replace function public.track_top_safeb_package(p_tracking_number text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_shipment public.package_shipments%rowtype;
  v_result jsonb;
begin
  if p_tracking_number is null
     or length(trim(p_tracking_number)) < 12
     or length(trim(p_tracking_number)) > 20
     or trim(p_tracking_number) !~* '^TSB-[A-Z0-9]{8,16}$' then
    return null;
  end if;

  select * into v_shipment
  from public.package_shipments
  where tracking_number = upper(trim(p_tracking_number));

  if not found then
    return null;
  end if;

  select jsonb_build_object(
    'tracking_number', v_shipment.tracking_number,
    'origin', v_shipment.origin,
    'destination', v_shipment.destination,
    'status', v_shipment.status,
    'dispatch_date', v_shipment.dispatch_date,
    'estimated_delivery_date', v_shipment.estimated_delivery_date,
    'delivered_at', v_shipment.delivered_at,
    'created_at', v_shipment.created_at,
    'events', coalesce((
      select jsonb_agg(jsonb_build_object(
        'status', e.status,
        'location', e.location,
        'note', e.public_note,
        'created_at', e.created_at
      ) order by e.created_at desc)
      from public.package_tracking_events e
      where e.shipment_id = v_shipment.id
    ), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$$;

revoke all on function public.track_top_safeb_package(text) from public;
grant execute on function public.track_top_safeb_package(text) to anon, authenticated;

-- Only trusted owner accounts listed in admin_users can create or update shipments.
-- Public tracking is read-only and exposes the limited JSON returned by the function.
