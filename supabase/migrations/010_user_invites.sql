alter table public.user_profiles
  add column if not exists email text;

create index if not exists user_profiles_center_email_idx
on public.user_profiles(center_id, lower(email))
where email is not null;
