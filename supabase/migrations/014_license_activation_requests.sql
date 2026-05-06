create table if not exists public.license_activation_requests (
  id uuid primary key,
  center_id uuid not null references public.centers(id) on delete cascade,
  plan_slug text not null,
  email text,
  device_id text not null,
  billing_interval text not null default 'monthly',
  status text not null default 'pending' check (status in ('pending', 'active', 'failed', 'cancelled', 'past_due')),
  provider_transaction_id text,
  provider_subscription_id text,
  license_key_prefix text,
  activated_at timestamptz,
  fulfilled_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists license_activation_requests_device_idx
on public.license_activation_requests (id, device_id);

create index if not exists license_activation_requests_center_created_idx
on public.license_activation_requests (center_id, created_at desc);

alter table public.license_activation_requests enable row level security;

create policy license_activation_requests_center_select
on public.license_activation_requests
for select
using (center_id = public.current_center_id());
