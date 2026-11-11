-- TopSafeB private support photo attachments
-- Run once in Supabase SQL Editor after live-support-chat.sql.
alter table public.support_messages
  add column if not exists attachment_path text;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'support-attachments',
  'support-attachments',
  false,
  5242880,
  array['image/jpeg','image/png','image/webp']
)
on conflict (id) do update
set public = false,
    file_size_limit = 5242880,
    allowed_mime_types = array['image/jpeg','image/png','image/webp'];

drop policy if exists "Customers upload own support photos" on storage.objects;
create policy "Customers upload own support photos"
on storage.objects for insert to authenticated
with check (
  bucket_id = 'support-attachments'
  and (storage.foldername(name))[1] = auth.uid()::text
);

drop policy if exists "Customers and admins view support photos" on storage.objects;
create policy "Customers and admins view support photos"
on storage.objects for select to authenticated
using (
  bucket_id = 'support-attachments'
  and (
    (storage.foldername(name))[1] = auth.uid()::text
    or exists (
      select 1 from public.admin_users au where au.user_id = auth.uid()
    )
  )
);

grant select, insert on storage.objects to authenticated;
