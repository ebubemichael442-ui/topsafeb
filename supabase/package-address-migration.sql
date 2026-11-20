-- Add a private customer delivery address to each package shipment.
-- Additive change only; existing shipment records and other TopSafeB tables remain intact.
alter table public.package_shipments
  add column if not exists recipient_address text not null default '';

alter table public.package_shipments
  drop constraint if exists package_shipments_recipient_address_check;

alter table public.package_shipments
  add constraint package_shipments_recipient_address_check
  check (length(trim(recipient_address)) <= 500);
