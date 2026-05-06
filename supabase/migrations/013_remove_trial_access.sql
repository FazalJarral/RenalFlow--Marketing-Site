-- Remove trial access from the SaaS billing model.

alter table public.subscriptions
  alter column status set default 'past_due';

update public.subscriptions
set
  status = 'past_due',
  trial_ends_at = null,
  updated_at = now()
where status = 'trialing';

create or replace function public.center_has_app_access(target_center_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1
    from public.subscriptions s
    where s.center_id = target_center_id
      and (
        s.status in ('active', 'lifetime')
        or s.lifetime_access
      )
  );
$$;
