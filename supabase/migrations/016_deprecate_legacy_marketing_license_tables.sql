do $$
begin
  if to_regclass('public.activation_requests') is not null then
    comment on table public.activation_requests is
      'Deprecated legacy marketing activation table. Canonical entitlement state is subscriptions, plans, center_usage_limits, license_activation_requests, license_keys, and billing_events.';
    revoke all on table public.activation_requests from anon, authenticated;
  end if;

  if to_regclass('public.licenses') is not null then
    comment on table public.licenses is
      'Deprecated legacy marketing license table. Do not use for RenalFlow app access or billing entitlement.';
    revoke all on table public.licenses from anon, authenticated;
  end if;
end $$;
