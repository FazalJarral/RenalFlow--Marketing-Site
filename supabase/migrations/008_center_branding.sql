alter table public.centers
  add column if not exists display_name text,
  add column if not exists logo_url text,
  add column if not exists brand_color text,
  add column if not exists tagline text;

drop policy if exists centers_admin_update on public.centers;
create policy centers_admin_update on public.centers
for update
using (id = public.current_center_id() and public.current_role()::text = 'center_admin')
with check (id = public.current_center_id() and public.current_role()::text = 'center_admin');

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('center-branding', 'center-branding', true, 5242880, array['image/jpeg','image/png','image/webp','image/svg+xml'])
on conflict (id) do update set
  public = true,
  file_size_limit = 5242880,
  allowed_mime_types = array['image/jpeg','image/png','image/webp','image/svg+xml'];

drop policy if exists storage_center_branding_insert on storage.objects;
drop policy if exists storage_center_branding_update on storage.objects;
drop policy if exists storage_center_branding_delete on storage.objects;

create policy storage_center_branding_insert on storage.objects for insert
with check (
  bucket_id = 'center-branding'
  and (storage.foldername(name))[1] = public.current_center_id()::text
  and public.current_role()::text = 'center_admin'
);

create policy storage_center_branding_update on storage.objects for update
using (
  bucket_id = 'center-branding'
  and (storage.foldername(name))[1] = public.current_center_id()::text
  and public.current_role()::text = 'center_admin'
)
with check (
  bucket_id = 'center-branding'
  and (storage.foldername(name))[1] = public.current_center_id()::text
  and public.current_role()::text = 'center_admin'
);

create policy storage_center_branding_delete on storage.objects for delete
using (
  bucket_id = 'center-branding'
  and (storage.foldername(name))[1] = public.current_center_id()::text
  and public.current_role()::text = 'center_admin'
);
