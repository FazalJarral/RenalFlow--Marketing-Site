-- SaaS subscription, license, and plan-limit layer.
-- Existing centers are granted an internal lifetime subscription at the end of
-- this migration so current clinical workflows remain available.

create type public.subscription_status as enum ('trialing', 'active', 'past_due', 'cancelled', 'lifetime');
create type public.license_key_status as enum ('active', 'revoked', 'expired');
create type public.billing_event_status as enum ('received', 'processed', 'failed');

create table public.plans (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text not null unique,
  price_monthly numeric(10, 2),
  price_lifetime numeric(10, 2),
  max_users int not null check (max_users > 0),
  max_patients int not null check (max_patients > 0),
  max_storage_mb int not null check (max_storage_mb >= 0),
  features jsonb not null default '{}'::jsonb,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.subscriptions (
  id uuid primary key default gen_random_uuid(),
  center_id uuid not null references public.centers(id) on delete cascade,
  plan_id uuid not null references public.plans(id) on delete restrict,
  status public.subscription_status not null default 'trialing',
  billing_provider text not null default 'manual',
  billing_customer_id text,
  billing_subscription_id text,
  current_period_start timestamptz,
  current_period_end timestamptz,
  lifetime_access boolean not null default false,
  trial_ends_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (center_id)
);

create table public.license_keys (
  id uuid primary key default gen_random_uuid(),
  center_id uuid not null references public.centers(id) on delete cascade,
  key_hash text not null unique,
  key_prefix text not null,
  status public.license_key_status not null default 'active',
  last_used_at timestamptz,
  expires_at timestamptz,
  created_at timestamptz not null default now(),
  revoked_at timestamptz
);

create table public.center_usage_limits (
  id uuid primary key default gen_random_uuid(),
  center_id uuid not null references public.centers(id) on delete cascade,
  plan_id uuid references public.plans(id) on delete set null,
  max_users int not null,
  max_patients int not null,
  max_storage_mb int not null,
  features jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (center_id)
);

create table public.billing_events (
  id uuid primary key default gen_random_uuid(),
  center_id uuid references public.centers(id) on delete set null,
  subscription_id uuid references public.subscriptions(id) on delete set null,
  provider text not null,
  event_type text not null,
  provider_event_id text,
  payload jsonb not null default '{}'::jsonb,
  status public.billing_event_status not null default 'received',
  error_message text,
  created_at timestamptz not null default now(),
  processed_at timestamptz,
  unique (provider, provider_event_id)
);

create index plans_active_slug_idx on public.plans (is_active, slug);
create index subscriptions_center_status_idx on public.subscriptions (center_id, status);
create index license_keys_center_status_idx on public.license_keys (center_id, status);
create index billing_events_center_created_idx on public.billing_events (center_id, created_at desc);

create or replace function public.center_has_app_access(target_center_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1
    from public.subscriptions s
    where s.center_id = target_center_id
      and (
        s.status in ('active', 'lifetime')
        or (s.status = 'trialing' and coalesce(s.trial_ends_at, now()) >= now())
        or s.lifetime_access
      )
  );
$$;

create or replace function public.current_center_has_app_access()
returns boolean language sql stable security definer set search_path = public as $$
  select public.center_has_app_access(public.current_center_id());
$$;

create or replace function public.current_center_subscription()
returns table (
  center_id uuid,
  plan_id uuid,
  plan_name text,
  plan_slug text,
  status public.subscription_status,
  lifetime_access boolean,
  trial_ends_at timestamptz,
  current_period_end timestamptz,
  max_users int,
  max_patients int,
  max_storage_mb int,
  features jsonb,
  active_user_count bigint,
  active_patient_count bigint
) language sql stable security definer set search_path = public as $$
  select
    s.center_id,
    p.id,
    p.name,
    p.slug,
    s.status,
    s.lifetime_access,
    s.trial_ends_at,
    s.current_period_end,
    coalesce(l.max_users, p.max_users),
    coalesce(l.max_patients, p.max_patients),
    coalesce(l.max_storage_mb, p.max_storage_mb),
    coalesce(l.features, p.features),
    (select count(*) from public.user_profiles u where u.center_id = s.center_id and u.status = 'active'),
    (select count(*) from public.patients pt where pt.center_id = s.center_id and pt.deleted_at is null and pt.status <> 'deceased')
  from public.subscriptions s
  join public.plans p on p.id = s.plan_id
  left join public.center_usage_limits l on l.center_id = s.center_id
  where s.center_id = public.current_center_id();
$$;

create or replace function public.center_plan_limit(target_center_id uuid, limit_name text)
returns int language sql stable security definer set search_path = public as $$
  select case limit_name
    when 'max_users' then coalesce(l.max_users, p.max_users)
    when 'max_patients' then coalesce(l.max_patients, p.max_patients)
    when 'max_storage_mb' then coalesce(l.max_storage_mb, p.max_storage_mb)
    else null
  end
  from public.subscriptions s
  join public.plans p on p.id = s.plan_id
  left join public.center_usage_limits l on l.center_id = s.center_id
  where s.center_id = target_center_id
  limit 1;
$$;

create or replace function public.ensure_center_has_access()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if not public.center_has_app_access(new.center_id) then
    raise exception 'RenalFlow access is blocked until billing is active for this center.'
      using errcode = 'P0001';
  end if;
  return new;
end;
$$;

create or replace function public.enforce_user_limit()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  allowed int;
  used int;
begin
  if new.status <> 'active' then
    return new;
  end if;

  allowed := public.center_plan_limit(new.center_id, 'max_users');
  if allowed is null then
    return new;
  end if;

  select count(*) into used
  from public.user_profiles
  where center_id = new.center_id
    and status = 'active'
    and id is distinct from new.id;

  if used + 1 > allowed then
    raise exception 'Plan user limit reached for this center.'
      using errcode = 'P0001';
  end if;
  return new;
end;
$$;

create or replace function public.enforce_patient_limit()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  allowed int;
  used int;
begin
  if new.deleted_at is not null or new.status = 'deceased' then
    return new;
  end if;

  allowed := public.center_plan_limit(new.center_id, 'max_patients');
  if allowed is null then
    return new;
  end if;

  select count(*) into used
  from public.patients
  where center_id = new.center_id
    and deleted_at is null
    and status <> 'deceased'
    and id is distinct from new.id;

  if used + 1 > allowed then
    raise exception 'Plan patient limit reached for this center.'
      using errcode = 'P0001';
  end if;
  return new;
end;
$$;

create or replace function public.sync_center_usage_limits()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  plan_row public.plans%rowtype;
begin
  select * into plan_row from public.plans where id = new.plan_id;
  if not found then
    return new;
  end if;

  insert into public.center_usage_limits(center_id, plan_id, max_users, max_patients, max_storage_mb, features)
  values (new.center_id, new.plan_id, plan_row.max_users, plan_row.max_patients, plan_row.max_storage_mb, plan_row.features)
  on conflict (center_id) do update set
    plan_id = excluded.plan_id,
    max_users = excluded.max_users,
    max_patients = excluded.max_patients,
    max_storage_mb = excluded.max_storage_mb,
    features = excluded.features,
    updated_at = now();
  return new;
end;
$$;

create trigger subscriptions_updated_at before update on public.subscriptions
for each row execute function public.set_updated_at();
create trigger plans_updated_at before update on public.plans
for each row execute function public.set_updated_at();
create trigger center_usage_limits_updated_at before update on public.center_usage_limits
for each row execute function public.set_updated_at();
create trigger subscriptions_sync_limits after insert or update of plan_id on public.subscriptions
for each row execute function public.sync_center_usage_limits();

create trigger user_profiles_plan_limit before insert or update on public.user_profiles
for each row execute function public.enforce_user_limit();
create trigger patients_plan_limit before insert or update on public.patients
for each row execute function public.enforce_patient_limit();

do $$
declare
  table_name text;
begin
  foreach table_name in array array[
    'patients', 'lab_test_templates', 'lab_unit_conversions', 'lab_reports',
    'lab_report_items', 'dialysis_sessions', 'session_vitals', 'vaccinations',
    'injections', 'schedules', 'notes', 'attachments', 'patient_nutrition_profiles',
    'nutrition_diet_plans', 'nutrition_meal_items', 'nutrition_restrictions',
    'nutrition_notes', 'lab_panels', 'lab_panel_tests', 'lab_report_panels',
    'lab_report_date_columns', 'lab_result_cells'
  ] loop
    if to_regclass('public.' || table_name) is not null then
      execute format('drop trigger if exists %I_saas_access on public.%I', table_name, table_name);
      execute format('create trigger %I_saas_access before insert or update on public.%I for each row execute function public.ensure_center_has_access()', table_name, table_name);
    end if;
  end loop;
end $$;

alter table public.plans enable row level security;
alter table public.subscriptions enable row level security;
alter table public.license_keys enable row level security;
alter table public.center_usage_limits enable row level security;
alter table public.billing_events enable row level security;

create policy plans_active_select on public.plans
for select using (is_active);

create policy subscriptions_center_select on public.subscriptions
for select using (center_id = public.current_center_id());

create policy license_keys_center_select on public.license_keys
for select using (center_id = public.current_center_id());

revoke all on table public.license_keys from anon, authenticated;
grant select (id, center_id, key_prefix, status, last_used_at, expires_at, created_at, revoked_at)
on table public.license_keys to authenticated;

create policy center_usage_limits_center_select on public.center_usage_limits
for select using (center_id = public.current_center_id());

create policy billing_events_center_select on public.billing_events
for select using (center_id = public.current_center_id());

insert into public.plans(name, slug, price_monthly, price_lifetime, max_users, max_patients, max_storage_mb, features)
values
  ('Starter', 'starter', 79, 1499, 8, 250, 2048, '{"lab_matrix": true, "nutrition": true, "audit_logs": true}'::jsonb),
  ('Growth', 'growth', 149, 2499, 25, 1000, 10240, '{"lab_matrix": true, "nutrition": true, "audit_logs": true, "priority_support": true}'::jsonb),
  ('Internal Lifetime', 'internal-lifetime', null, 0, 1000, 100000, 1048576, '{"lab_matrix": true, "nutrition": true, "audit_logs": true, "internal": true}'::jsonb)
on conflict (slug) do update set
  name = excluded.name,
  price_monthly = excluded.price_monthly,
  price_lifetime = excluded.price_lifetime,
  max_users = excluded.max_users,
  max_patients = excluded.max_patients,
  max_storage_mb = excluded.max_storage_mb,
  features = excluded.features,
  is_active = true,
  updated_at = now();

insert into public.subscriptions(center_id, plan_id, status, billing_provider, lifetime_access, current_period_start)
select c.id, p.id, 'lifetime', 'manual', true, now()
from public.centers c
cross join public.plans p
where p.slug = 'internal-lifetime'
on conflict (center_id) do nothing;
