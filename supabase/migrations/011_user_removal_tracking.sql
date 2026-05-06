alter table public.user_profiles
  add column if not exists invited_at timestamptz,
  add column if not exists accepted_at timestamptz,
  add column if not exists removed_at timestamptz;

create index if not exists user_profiles_center_removed_idx
on public.user_profiles(center_id, removed_at);
