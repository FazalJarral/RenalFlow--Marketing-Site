alter table public.user_profiles
  drop constraint if exists user_profiles_auth_user_id_key;

create unique index if not exists user_profiles_center_auth_user_unique
on public.user_profiles(center_id, auth_user_id);

create or replace function public.current_profile_id()
returns uuid language sql stable security definer set search_path = public as $$
  select id
  from public.user_profiles
  where auth_user_id = auth.uid()
    and status = 'active'
    and removed_at is null
  order by accepted_at desc nulls last, updated_at desc
  limit 1
$$;

create or replace function public.current_center_id()
returns uuid language sql stable security definer set search_path = public as $$
  select center_id
  from public.user_profiles
  where auth_user_id = auth.uid()
    and status = 'active'
    and removed_at is null
  order by accepted_at desc nulls last, updated_at desc
  limit 1
$$;

create or replace function public.current_role()
returns public.user_role language sql stable security definer set search_path = public as $$
  select role
  from public.user_profiles
  where auth_user_id = auth.uid()
    and status = 'active'
    and removed_at is null
  order by accepted_at desc nulls last, updated_at desc
  limit 1
$$;
