-- Optional real courier identifiers for TopSafeB shipments.
-- Additive only: preserves existing shipments and existing TSB tracking references.
-- These fields remain owner-only; do not add them to the public tracking RPC response.

alter table public.package_shipments
  add column if not exists carrier_name text,
  add column if not exists carrier_tracking_number text;

alter table public.package_shipments
  drop constraint if exists package_shipments_carrier_name_check,
  drop constraint if exists package_shipments_carrier_tracking_number_check;

alter table public.package_shipments
  add constraint package_shipments_carrier_name_check
    check (carrier_name is null or length(trim(carrier_name)) <= 120),
  add constraint package_shipments_carrier_tracking_number_check
    check (carrier_tracking_number is null or length(trim(carrier_tracking_number)) <= 160);

create index if not exists package_shipments_carrier_tracking_idx
  on public.package_shipments(carrier_tracking_number)
  where carrier_tracking_number is not null;
