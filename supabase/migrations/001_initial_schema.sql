-- RenalFlow initial multi-tenant schema.
-- Future-ready note: a platform owner/super-admin role can be added later by
-- extending role enums and policies. MVP policies intentionally only expose
-- center-scoped users.

create extension if not exists pgcrypto;

create type public.user_role as enum ('center_admin', 'doctor', 'technician');
create type public.record_status as enum ('active', 'inactive');
create type public.patient_status as enum ('active', 'paused', 'transferred', 'deceased');
create type public.lab_category as enum (
  'blood_cp_cbc', 'lft', 'rft', 'hepatitis_profile', 'calcium_phosphate',
  'ferritin', 'serum_electrolytes', 'pth', 'albumin', 'hba1c', 'blood_sugar', 'custom'
);
create type public.lab_item_status as enum ('low', 'normal', 'high', 'critical_low', 'critical_high', 'unknown');
create type public.session_status as enum ('scheduled', 'in_progress', 'completed', 'missed', 'cancelled', 'early_terminated');
create type public.vital_phase as enum ('pre', 'during', 'post');
create type public.injection_route as enum ('IV', 'SC', 'IM', 'oral', 'other');
create type public.note_type as enum ('technician', 'doctor', 'general');
create type public.audit_action as enum ('create', 'update', 'delete', 'restore');

create table public.centers (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  address text,
  phone text,
  email text,
  status public.record_status not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.user_profiles (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid not null unique references auth.users(id) on delete cascade,
  center_id uuid not null references public.centers(id) on delete restrict,
  full_name text not null,
  role public.user_role not null,
  status public.record_status not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.patients (
  id uuid primary key default gen_random_uuid(),
  center_id uuid not null references public.centers(id) on delete restrict,
  patient_id text not null,
  full_name text not null,
  dob date,
  age int,
  gender text,
  phone text,
  emergency_contact_name text,
  emergency_contact_phone text,
  address text,
  blood_group text,
  cnic_or_identifier text,
  dialysis_start_date date,
  diagnosis text,
  comorbidities text,
  allergies text,
  current_medications text,
  vascular_access_type text,
  vascular_access_location text,
  assigned_doctor_id uuid references public.user_profiles(id),
  status public.patient_status not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  unique (center_id, patient_id)
);

create table public.lab_test_templates (
  id uuid primary key default gen_random_uuid(),
  center_id uuid not null references public.centers(id) on delete cascade,
  name text not null,
  category public.lab_category not null,
  default_unit text not null,
  standard_unit text not null,
  allowed_units text[] not null default '{}',
  normal_min numeric,
  normal_max numeric,
  critical_low numeric,
  critical_high numeric,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (center_id, name, category)
);

create table public.lab_unit_conversions (
  id uuid primary key default gen_random_uuid(),
  center_id uuid not null references public.centers(id) on delete cascade,
  test_template_id uuid not null references public.lab_test_templates(id) on delete cascade,
  from_unit text not null,
  to_unit text not null,
  multiplier numeric not null default 1,
  formula_offset numeric not null default 0,
  formula_type text not null default 'linear' check (formula_type = 'linear'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (center_id, test_template_id, from_unit, to_unit)
);

create table public.lab_reports (
  id uuid primary key default gen_random_uuid(),
  center_id uuid not null references public.centers(id) on delete restrict,
  patient_id uuid not null references public.patients(id) on delete restrict,
  report_date date not null,
  lab_name text,
  category public.lab_category not null default 'custom',
  uploaded_file_url text,
  notes text,
  created_by uuid references public.user_profiles(id),
  reviewed_by uuid references public.user_profiles(id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create table public.lab_report_items (
  id uuid primary key default gen_random_uuid(),
  center_id uuid not null references public.centers(id) on delete restrict,
  lab_report_id uuid not null references public.lab_reports(id) on delete cascade,
  patient_id uuid not null references public.patients(id) on delete restrict,
  test_template_id uuid references public.lab_test_templates(id),
  test_name_snapshot text not null,
  value numeric not null,
  unit text not null,
  standardized_value numeric not null,
  standard_unit_snapshot text not null,
  normal_min_snapshot numeric,
  normal_max_snapshot numeric,
  critical_low_snapshot numeric,
  critical_high_snapshot numeric,
  status public.lab_item_status not null default 'unknown',
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.dialysis_sessions (
  id uuid primary key default gen_random_uuid(),
  center_id uuid not null references public.centers(id) on delete restrict,
  patient_id uuid not null references public.patients(id) on delete restrict,
  session_date date not null,
  start_time timestamptz,
  end_time timestamptz,
  status public.session_status not null default 'scheduled',
  assigned_technician_id uuid references public.user_profiles(id),
  assigned_doctor_id uuid references public.user_profiles(id),
  machine_number text,
  pre_weight numeric,
  post_weight numeric,
  dry_weight numeric,
  weight_gain numeric,
  uf_target numeric,
  uf_achieved numeric,
  dialyzer_used text,
  blood_flow_rate numeric,
  dialysate_flow_rate numeric,
  heparin_dose text,
  complications text[] not null default '{}',
  early_termination_reason text,
  technician_notes text,
  doctor_notes text,
  reviewed_by uuid references public.user_profiles(id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create table public.session_vitals (
  id uuid primary key default gen_random_uuid(),
  center_id uuid not null references public.centers(id) on delete restrict,
  session_id uuid not null references public.dialysis_sessions(id) on delete cascade,
  patient_id uuid not null references public.patients(id) on delete restrict,
  recorded_at timestamptz not null default now(),
  phase public.vital_phase not null,
  bp_systolic int,
  bp_diastolic int,
  pulse int,
  sugar numeric,
  temperature numeric,
  spo2 numeric,
  respiratory_rate int,
  notes text,
  created_by uuid references public.user_profiles(id),
  created_at timestamptz not null default now()
);

create table public.vaccinations (
  id uuid primary key default gen_random_uuid(),
  center_id uuid not null references public.centers(id) on delete restrict,
  patient_id uuid not null references public.patients(id) on delete restrict,
  vaccine_name text not null,
  dose_number text,
  date_given date not null,
  next_due_date date,
  batch_number text,
  given_by uuid references public.user_profiles(id),
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create table public.injections (
  id uuid primary key default gen_random_uuid(),
  center_id uuid not null references public.centers(id) on delete restrict,
  patient_id uuid not null references public.patients(id) on delete restrict,
  session_id uuid references public.dialysis_sessions(id) on delete set null,
  name text not null,
  dose numeric,
  unit text,
  route public.injection_route not null default 'other',
  given_at timestamptz not null default now(),
  given_by uuid references public.user_profiles(id),
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create table public.schedules (
  id uuid primary key default gen_random_uuid(),
  center_id uuid not null references public.centers(id) on delete restrict,
  patient_id uuid not null references public.patients(id) on delete restrict,
  regular_days text[] not null default '{}',
  shift text,
  next_session_at timestamptz,
  machine_number text,
  assigned_technician_id uuid references public.user_profiles(id),
  assigned_doctor_id uuid references public.user_profiles(id),
  status public.record_status not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create table public.notes (
  id uuid primary key default gen_random_uuid(),
  center_id uuid not null references public.centers(id) on delete restrict,
  patient_id uuid not null references public.patients(id) on delete restrict,
  session_id uuid references public.dialysis_sessions(id) on delete set null,
  note_type public.note_type not null default 'general',
  body text not null,
  created_by uuid references public.user_profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create table public.attachments (
  id uuid primary key default gen_random_uuid(),
  center_id uuid not null references public.centers(id) on delete restrict,
  patient_id uuid not null references public.patients(id) on delete restrict,
  lab_report_id uuid references public.lab_reports(id) on delete set null,
  session_id uuid references public.dialysis_sessions(id) on delete set null,
  file_name text not null,
  file_type text not null check (file_type in ('application/pdf', 'image/jpeg', 'image/png')),
  file_url text not null,
  storage_path text not null,
  uploaded_by uuid references public.user_profiles(id),
  created_at timestamptz not null default now(),
  deleted_at timestamptz
);

create table public.audit_logs (
  id uuid primary key default gen_random_uuid(),
  center_id uuid not null references public.centers(id) on delete restrict,
  user_id uuid references public.user_profiles(id),
  entity_type text not null,
  entity_id uuid not null,
  action public.audit_action not null,
  before_data jsonb,
  after_data jsonb,
  created_at timestamptz not null default now()
);

create index on public.user_profiles (auth_user_id, center_id);
create index on public.patients (center_id, full_name) where deleted_at is null;
create index on public.lab_reports (center_id, patient_id, report_date desc) where deleted_at is null;
create index on public.lab_report_items (center_id, patient_id, test_template_id);
create index on public.dialysis_sessions (center_id, session_date, status) where deleted_at is null;
create index on public.session_vitals (center_id, session_id, recorded_at);
create index on public.schedules (center_id, next_session_at) where deleted_at is null;
create index on public.audit_logs (center_id, created_at desc);

create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create or replace function public.current_profile_id()
returns uuid language sql stable security definer set search_path = public as $$
  select id from public.user_profiles where auth_user_id = auth.uid() and status = 'active' limit 1
$$;

create or replace function public.current_center_id()
returns uuid language sql stable security definer set search_path = public as $$
  select center_id from public.user_profiles where auth_user_id = auth.uid() and status = 'active' limit 1
$$;

create or replace function public.current_role()
returns public.user_role language sql stable security definer set search_path = public as $$
  select role from public.user_profiles where auth_user_id = auth.uid() and status = 'active' limit 1
$$;

create or replace function public.set_tenant_columns()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.center_id is null then
    new.center_id = public.current_center_id();
  end if;
  if new.center_id is distinct from public.current_center_id() then
    raise exception 'center_id must match current user center';
  end if;
  return new;
end;
$$;

create or replace function public.assert_same_center(ref_table text, ref_id uuid, field_name text, expected_center_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  actual_center_id uuid;
begin
  if ref_id is null then
    return;
  end if;

  execute format('select center_id from public.%I where id = $1', ref_table)
    into actual_center_id
    using ref_id;

  if actual_center_id is null then
    raise exception 'Invalid reference %.%', ref_table, field_name;
  end if;

  if actual_center_id is distinct from expected_center_id then
    raise exception 'Reference %.% must belong to the same center', ref_table, field_name;
  end if;
end;
$$;

create or replace function public.assert_same_patient(ref_table text, ref_id uuid, field_name text, expected_patient_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  actual_patient_id uuid;
begin
  if ref_id is null or expected_patient_id is null then
    return;
  end if;

  execute format('select patient_id from public.%I where id = $1', ref_table)
    into actual_patient_id
    using ref_id;

  if actual_patient_id is distinct from expected_patient_id then
    raise exception 'Reference %.% must belong to the same patient', ref_table, field_name;
  end if;
end;
$$;

create or replace function public.validate_tenant_references()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_table_name = 'patients' then
    perform public.assert_same_center('user_profiles', new.assigned_doctor_id, 'assigned_doctor_id', new.center_id);
  elsif tg_table_name = 'lab_unit_conversions' then
    perform public.assert_same_center('lab_test_templates', new.test_template_id, 'test_template_id', new.center_id);
  elsif tg_table_name = 'lab_reports' then
    perform public.assert_same_center('patients', new.patient_id, 'patient_id', new.center_id);
    perform public.assert_same_center('user_profiles', new.created_by, 'created_by', new.center_id);
    perform public.assert_same_center('user_profiles', new.reviewed_by, 'reviewed_by', new.center_id);
  elsif tg_table_name = 'lab_report_items' then
    perform public.assert_same_center('lab_reports', new.lab_report_id, 'lab_report_id', new.center_id);
    perform public.assert_same_center('patients', new.patient_id, 'patient_id', new.center_id);
    perform public.assert_same_center('lab_test_templates', new.test_template_id, 'test_template_id', new.center_id);
    perform public.assert_same_patient('lab_reports', new.lab_report_id, 'lab_report_id', new.patient_id);
  elsif tg_table_name = 'dialysis_sessions' then
    perform public.assert_same_center('patients', new.patient_id, 'patient_id', new.center_id);
    perform public.assert_same_center('user_profiles', new.assigned_technician_id, 'assigned_technician_id', new.center_id);
    perform public.assert_same_center('user_profiles', new.assigned_doctor_id, 'assigned_doctor_id', new.center_id);
    perform public.assert_same_center('user_profiles', new.reviewed_by, 'reviewed_by', new.center_id);
  elsif tg_table_name = 'session_vitals' then
    perform public.assert_same_center('dialysis_sessions', new.session_id, 'session_id', new.center_id);
    perform public.assert_same_center('patients', new.patient_id, 'patient_id', new.center_id);
    perform public.assert_same_center('user_profiles', new.created_by, 'created_by', new.center_id);
    perform public.assert_same_patient('dialysis_sessions', new.session_id, 'session_id', new.patient_id);
  elsif tg_table_name = 'vaccinations' then
    perform public.assert_same_center('patients', new.patient_id, 'patient_id', new.center_id);
    perform public.assert_same_center('user_profiles', new.given_by, 'given_by', new.center_id);
  elsif tg_table_name = 'injections' then
    perform public.assert_same_center('patients', new.patient_id, 'patient_id', new.center_id);
    perform public.assert_same_center('dialysis_sessions', new.session_id, 'session_id', new.center_id);
    perform public.assert_same_center('user_profiles', new.given_by, 'given_by', new.center_id);
    perform public.assert_same_patient('dialysis_sessions', new.session_id, 'session_id', new.patient_id);
  elsif tg_table_name = 'schedules' then
    perform public.assert_same_center('patients', new.patient_id, 'patient_id', new.center_id);
    perform public.assert_same_center('user_profiles', new.assigned_technician_id, 'assigned_technician_id', new.center_id);
    perform public.assert_same_center('user_profiles', new.assigned_doctor_id, 'assigned_doctor_id', new.center_id);
  elsif tg_table_name = 'notes' then
    perform public.assert_same_center('patients', new.patient_id, 'patient_id', new.center_id);
    perform public.assert_same_center('dialysis_sessions', new.session_id, 'session_id', new.center_id);
    perform public.assert_same_center('user_profiles', new.created_by, 'created_by', new.center_id);
    perform public.assert_same_patient('dialysis_sessions', new.session_id, 'session_id', new.patient_id);
  elsif tg_table_name = 'attachments' then
    perform public.assert_same_center('patients', new.patient_id, 'patient_id', new.center_id);
    perform public.assert_same_center('lab_reports', new.lab_report_id, 'lab_report_id', new.center_id);
    perform public.assert_same_center('dialysis_sessions', new.session_id, 'session_id', new.center_id);
    perform public.assert_same_center('user_profiles', new.uploaded_by, 'uploaded_by', new.center_id);
    perform public.assert_same_patient('lab_reports', new.lab_report_id, 'lab_report_id', new.patient_id);
    perform public.assert_same_patient('dialysis_sessions', new.session_id, 'session_id', new.patient_id);
  elsif tg_table_name = 'audit_logs' then
    perform public.assert_same_center('user_profiles', new.user_id, 'user_id', new.center_id);
  end if;

  return new;
end;
$$;

revoke execute on function public.assert_same_center(text, uuid, text, uuid) from anon, authenticated;
revoke execute on function public.assert_same_patient(text, uuid, text, uuid) from anon, authenticated;
revoke execute on function public.validate_tenant_references() from anon, authenticated;

create or replace function public.audit_row_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  row_center uuid;
  row_id uuid;
begin
  row_center = coalesce(new.center_id, old.center_id);
  row_id = coalesce(new.id, old.id);
  insert into public.audit_logs(center_id, user_id, entity_type, entity_id, action, before_data, after_data)
  values (
    row_center,
    public.current_profile_id(),
    tg_table_name,
    row_id,
    case tg_op when 'INSERT' then 'create'::public.audit_action when 'UPDATE' then 'update'::public.audit_action else 'delete'::public.audit_action end,
    case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) else null end,
    case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) else null end
  );
  return coalesce(new, old);
end;
$$;

create or replace function public.set_lab_item_status()
returns trigger language plpgsql as $$
begin
  new.status = case
    when new.critical_low_snapshot is not null and new.standardized_value <= new.critical_low_snapshot then 'critical_low'::public.lab_item_status
    when new.critical_high_snapshot is not null and new.standardized_value >= new.critical_high_snapshot then 'critical_high'::public.lab_item_status
    when new.normal_min_snapshot is not null and new.standardized_value < new.normal_min_snapshot then 'low'::public.lab_item_status
    when new.normal_max_snapshot is not null and new.standardized_value > new.normal_max_snapshot then 'high'::public.lab_item_status
    when new.normal_min_snapshot is null and new.normal_max_snapshot is null then 'unknown'::public.lab_item_status
    else 'normal'::public.lab_item_status
  end;
  return new;
end;
$$;

do $$
declare t text;
begin
  foreach t in array array['centers','user_profiles','patients','lab_test_templates','lab_unit_conversions','lab_reports','lab_report_items','dialysis_sessions','vaccinations','injections','schedules','notes'] loop
    execute format('create trigger %I_updated_at before update on public.%I for each row execute function public.set_updated_at()', t, t);
  end loop;

  foreach t in array array['patients','lab_test_templates','lab_unit_conversions','lab_reports','lab_report_items','dialysis_sessions','session_vitals','vaccinations','injections','schedules','notes','attachments'] loop
    execute format('create trigger %I_set_tenant before insert on public.%I for each row execute function public.set_tenant_columns()', t, t);
  end loop;

  foreach t in array array['patients','lab_unit_conversions','lab_reports','lab_report_items','dialysis_sessions','session_vitals','vaccinations','injections','schedules','notes','attachments','audit_logs'] loop
    execute format('create trigger %I_validate_tenant_references before insert or update on public.%I for each row execute function public.validate_tenant_references()', t, t);
  end loop;

  foreach t in array array['patients','lab_reports','lab_report_items','dialysis_sessions','session_vitals','vaccinations','injections','schedules','notes','attachments','lab_test_templates','lab_unit_conversions'] loop
    execute format('create trigger %I_audit after insert or update or delete on public.%I for each row execute function public.audit_row_change()', t, t);
  end loop;
end $$;

create trigger lab_report_items_status before insert or update on public.lab_report_items
for each row execute function public.set_lab_item_status();

alter table public.centers enable row level security;
alter table public.user_profiles enable row level security;
alter table public.patients enable row level security;
alter table public.lab_test_templates enable row level security;
alter table public.lab_unit_conversions enable row level security;
alter table public.lab_reports enable row level security;
alter table public.lab_report_items enable row level security;
alter table public.dialysis_sessions enable row level security;
alter table public.session_vitals enable row level security;
alter table public.vaccinations enable row level security;
alter table public.injections enable row level security;
alter table public.schedules enable row level security;
alter table public.notes enable row level security;
alter table public.attachments enable row level security;
alter table public.audit_logs enable row level security;

create policy centers_own_select on public.centers for select using (id = public.current_center_id());
create policy profiles_own_center_select on public.user_profiles for select using (center_id = public.current_center_id());
create policy profiles_admin_insert on public.user_profiles for insert with check (center_id = public.current_center_id() and public.current_role() = 'center_admin');
create policy profiles_admin_update on public.user_profiles for update using (center_id = public.current_center_id() and public.current_role() = 'center_admin') with check (center_id = public.current_center_id());

create policy audit_center_select on public.audit_logs for select using (center_id = public.current_center_id() and public.current_role() = 'center_admin');
create policy audit_system_insert on public.audit_logs for insert with check (center_id = public.current_center_id());

create or replace function public.role_can_read()
returns boolean language sql stable as $$ select public.current_role() in ('center_admin','doctor','technician') $$;

create or replace function public.role_can_operate()
returns boolean language sql stable as $$ select public.current_role() in ('center_admin','technician') $$;

create or replace function public.role_can_clinical_note()
returns boolean language sql stable as $$ select public.current_role() in ('center_admin','doctor','technician') $$;

do $$
declare t text;
begin
  foreach t in array array['patients','lab_reports','lab_report_items','dialysis_sessions','session_vitals','vaccinations','injections','schedules','notes','attachments','lab_test_templates','lab_unit_conversions'] loop
    execute format('create policy %I_center_select on public.%I for select using (center_id = public.current_center_id() and public.role_can_read())', t, t);
  end loop;

  foreach t in array array['patients','lab_test_templates','lab_unit_conversions','schedules'] loop
    execute format('create policy %I_admin_insert on public.%I for insert with check (center_id = public.current_center_id() and public.current_role() = ''center_admin'')', t, t);
    execute format('create policy %I_admin_update on public.%I for update using (center_id = public.current_center_id() and public.current_role() = ''center_admin'') with check (center_id = public.current_center_id())', t, t);
    execute format('create policy %I_admin_delete on public.%I for delete using (center_id = public.current_center_id() and public.current_role() = ''center_admin'')', t, t);
  end loop;

  foreach t in array array['lab_reports','lab_report_items','dialysis_sessions','session_vitals','vaccinations','injections','attachments'] loop
    execute format('create policy %I_ops_insert on public.%I for insert with check (center_id = public.current_center_id() and public.role_can_operate())', t, t);
    execute format('create policy %I_ops_update on public.%I for update using (center_id = public.current_center_id() and public.role_can_operate()) with check (center_id = public.current_center_id())', t, t);
  end loop;
end $$;

create policy notes_insert on public.notes for insert
with check (
  center_id = public.current_center_id()
  and public.role_can_clinical_note()
  and (
    public.current_role() = 'center_admin'
    or (public.current_role() = 'doctor' and note_type in ('doctor','general'))
    or (public.current_role() = 'technician' and note_type in ('technician','general'))
  )
);
create policy notes_update on public.notes for update
using (center_id = public.current_center_id() and created_by = public.current_profile_id())
with check (center_id = public.current_center_id());

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('patient-attachments', 'patient-attachments', false, 20971520, array['application/pdf','image/jpeg','image/png'])
on conflict (id) do update set public = false;

create policy storage_read_center_files on storage.objects for select
using (bucket_id = 'patient-attachments' and (storage.foldername(name))[1] = public.current_center_id()::text);
create policy storage_insert_center_files on storage.objects for insert
with check (
  bucket_id = 'patient-attachments'
  and (storage.foldername(name))[1] = public.current_center_id()::text
  and public.current_role() in ('center_admin','technician')
);
create policy storage_update_center_files on storage.objects for update
using (bucket_id = 'patient-attachments' and (storage.foldername(name))[1] = public.current_center_id()::text and public.current_role() in ('center_admin','technician'));
