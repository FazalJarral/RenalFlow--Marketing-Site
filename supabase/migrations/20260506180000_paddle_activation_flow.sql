create extension if not exists pgcrypto;

do $$ begin
  create type activation_request_status as enum ('pending', 'paid', 'expired', 'failed');
exception
  when duplicate_object then null;
end $$;

do $$ begin
  create type license_status as enum ('active', 'inactive', 'past_due', 'cancelled');
exception
  when duplicate_object then null;
end $$;

create table if not exists public.activation_requests (
  id uuid primary key default gen_random_uuid(),
  activation_request_id text not null unique,
  email text,
  selected_plan text not null,
  status activation_request_status not null default 'pending',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.licenses (
  id uuid primary key default gen_random_uuid(),
  license_key text not null unique,
  activation_request_id text not null references public.activation_requests (activation_request_id) on delete cascade,
  email text,
  paddle_customer_id text,
  paddle_subscription_id text,
  paddle_transaction_id text,
  plan text not null,
  status license_status not null default 'inactive',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint licenses_activation_request_id_key unique (activation_request_id)
);

create unique index if not exists licenses_paddle_subscription_id_key
  on public.licenses (paddle_subscription_id)
  where paddle_subscription_id is not null;

create unique index if not exists licenses_paddle_transaction_id_key
  on public.licenses (paddle_transaction_id)
  where paddle_transaction_id is not null;

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists touch_activation_requests_updated_at on public.activation_requests;
create trigger touch_activation_requests_updated_at
before update on public.activation_requests
for each row execute function public.touch_updated_at();

drop trigger if exists touch_licenses_updated_at on public.licenses;
create trigger touch_licenses_updated_at
before update on public.licenses
for each row execute function public.touch_updated_at();

alter table public.activation_requests enable row level security;
alter table public.licenses enable row level security;

-- These tables are written by the Paddle webhook with SUPABASE_SERVICE_ROLE_KEY.
-- Do not grant anonymous policies for license provisioning or activation status changes.
