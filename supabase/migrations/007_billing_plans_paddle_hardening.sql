-- Harden public SaaS plan catalog for Paddle billing.
-- Core clinical features stay available on every public plan; plans differ by
-- limits and support/analytics flags only.

do $$
begin
  if not exists (
    select 1
    from pg_description d
    join pg_class c on c.oid = d.objoid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = 'center_usage_limits'
      and d.description like 'TODO: storage enforcement%'
  ) then
    comment on table public.center_usage_limits is
      'TODO: storage enforcement requires reliable attachment/storage byte accounting. Until storage object sizes are synced into relational rows, show storage limit and usage as unavailable rather than blocking clinical attachment workflows.';
  end if;
end $$;

insert into public.plans(name, slug, price_monthly, price_lifetime, max_users, max_patients, max_storage_mb, features, is_active)
values
  (
    'Starter',
    'starter',
    39,
    null,
    3,
    100,
    2048,
    '{
      "clinical_core": true,
      "labs": true,
      "nutrition": true,
      "sessions": true,
      "vitals": true,
      "attachments": true,
      "pdf_export": true,
      "audit_logs": true,
      "analytics": false,
      "priority_support": false,
      "support": "standard"
    }'::jsonb,
    true
  ),
  (
    'Growth',
    'growth',
    99,
    null,
    10,
    500,
    10240,
    '{
      "clinical_core": true,
      "labs": true,
      "nutrition": true,
      "sessions": true,
      "vitals": true,
      "attachments": true,
      "pdf_export": true,
      "audit_logs": true,
      "analytics": false,
      "priority_support": false,
      "support": "standard",
      "recommended": true
    }'::jsonb,
    true
  ),
  (
    'Pro',
    'pro',
    249,
    null,
    25,
    1500,
    51200,
    '{
      "clinical_core": true,
      "labs": true,
      "nutrition": true,
      "sessions": true,
      "vitals": true,
      "attachments": true,
      "pdf_export": true,
      "audit_logs": true,
      "analytics": true,
      "priority_support": true,
      "support": "priority"
    }'::jsonb,
    true
  ),
  (
    'Internal Lifetime',
    'internal-lifetime',
    null,
    0,
    1000,
    100000,
    1048576,
    '{
      "clinical_core": true,
      "labs": true,
      "nutrition": true,
      "sessions": true,
      "vitals": true,
      "attachments": true,
      "pdf_export": true,
      "audit_logs": true,
      "analytics": true,
      "priority_support": true,
      "internal": true,
      "support": "internal"
    }'::jsonb,
    true
  )
on conflict (slug) do update set
  name = excluded.name,
  price_monthly = excluded.price_monthly,
  price_lifetime = excluded.price_lifetime,
  max_users = excluded.max_users,
  max_patients = excluded.max_patients,
  max_storage_mb = excluded.max_storage_mb,
  features = excluded.features,
  is_active = excluded.is_active,
  updated_at = now();

update public.center_usage_limits l
set
  plan_id = p.id,
  max_users = p.max_users,
  max_patients = p.max_patients,
  max_storage_mb = p.max_storage_mb,
  features = p.features,
  updated_at = now()
from public.subscriptions s
join public.plans p on p.id = s.plan_id
where l.center_id = s.center_id
  and p.slug in ('starter', 'growth', 'pro', 'internal-lifetime');
