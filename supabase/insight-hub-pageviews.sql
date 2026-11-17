-- TopSafeB Insight Hub: privacy-conscious page-view counter
-- Safe, additive migration. Does not alter customer, demo-funds, transfer, or support tables.
-- Run once in the existing TopSafeB Supabase SQL Editor.

create table if not exists public.insight_hub_pageviews (
  id bigint generated always as identity primary key,
  page_path text not null check (length(page_path) between 1 and 160),
  created_at timestamptz not null default now()
);

create index if not exists insight_hub_pageviews_created_at_idx
  on public.insight_hub_pageviews (created_at desc);

alter table public.insight_hub_pageviews enable row level security;

drop policy if exists "Public can record limited page views" on public.insight_hub_pageviews;
create policy "Public can record limited page views"
on public.insight_hub_pageviews
for insert to anon, authenticated
with check (
  length(page_path) between 1 and 160
  and page_path ~ '^/[A-Za-z0-9_./-]*$'
);

drop policy if exists "TopSafeB admins can read Insight Hub page views" on public.insight_hub_pageviews;
create policy "TopSafeB admins can read Insight Hub page views"
on public.insight_hub_pageviews
for select to authenticated
using (
  exists (
    select 1 from public.admin_users a
    where a.user_id = auth.uid()
  )
);

revoke all on public.insight_hub_pageviews from public;
grant insert on public.insight_hub_pageviews to anon, authenticated;
grant select on public.insight_hub_pageviews to authenticated;
