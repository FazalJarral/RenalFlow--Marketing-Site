alter type public.user_role add value if not exists 'nutritionist';

create type public.nutrition_diet_type as enum ('renal', 'diabetic_renal', 'low_potassium', 'low_phosphorus', 'low_sodium', 'custom');
create type public.nutrition_appetite_level as enum ('good', 'fair', 'poor', 'very_poor');
create type public.nutrition_plan_status as enum ('draft', 'active', 'archived');
create type public.nutrition_meal_type as enum ('breakfast', 'morning_snack', 'lunch', 'evening_snack', 'dinner', 'bedtime_snack', 'custom');
create type public.nutrition_restriction_type as enum ('high_potassium', 'high_phosphorus', 'high_sodium', 'fluid', 'allergy', 'custom');
create type public.nutrition_severity as enum ('low', 'medium', 'high');
create type public.attachment_context as enum ('lab_report', 'session', 'nutrition_plan', 'nutrition_report', 'food_chart', 'other');

alter table public.attachments
  add column if not exists attachment_context public.attachment_context;

create table public.patient_nutrition_profiles (
  id uuid primary key default gen_random_uuid(),
  center_id uuid not null references public.centers(id) on delete restrict,
  patient_id uuid not null references public.patients(id) on delete restrict,
  diet_type public.nutrition_diet_type not null default 'renal',
  appetite_level public.nutrition_appetite_level not null default 'fair',
  has_diabetes boolean not null default false,
  has_hypertension boolean not null default false,
  food_allergies text,
  food_preferences text,
  food_dislikes text,
  cultural_notes text,
  fluid_restriction_ml_per_day numeric,
  target_calories_per_day numeric,
  target_protein_g_per_day numeric,
  target_sodium_mg_per_day numeric,
  target_potassium_mg_per_day numeric,
  target_phosphorus_mg_per_day numeric,
  notes text,
  created_by uuid references public.user_profiles(id),
  updated_by uuid references public.user_profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create table public.nutrition_diet_plans (
  id uuid primary key default gen_random_uuid(),
  center_id uuid not null references public.centers(id) on delete restrict,
  patient_id uuid not null references public.patients(id) on delete restrict,
  nutrition_profile_id uuid references public.patient_nutrition_profiles(id) on delete set null,
  title text not null,
  status public.nutrition_plan_status not null default 'draft',
  start_date date not null default current_date,
  end_date date,
  total_calories_per_day numeric,
  total_protein_g_per_day numeric,
  total_fluid_ml_per_day numeric,
  total_sodium_mg_per_day numeric,
  total_potassium_mg_per_day numeric,
  total_phosphorus_mg_per_day numeric,
  general_instructions text,
  created_by uuid references public.user_profiles(id),
  updated_by uuid references public.user_profiles(id),
  reviewed_by uuid references public.user_profiles(id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz
);

create table public.nutrition_meal_items (
  id uuid primary key default gen_random_uuid(),
  center_id uuid not null references public.centers(id) on delete restrict,
  diet_plan_id uuid not null references public.nutrition_diet_plans(id) on delete cascade,
  meal_time time,
  meal_type public.nutrition_meal_type not null default 'custom',
  food_name text not null,
  portion_size text,
  approximate_calories numeric,
  protein_g numeric,
  sodium_mg numeric,
  potassium_mg numeric,
  phosphorus_mg numeric,
  fluid_ml numeric,
  preparation_notes text,
  alternatives text,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.nutrition_restrictions (
  id uuid primary key default gen_random_uuid(),
  center_id uuid not null references public.centers(id) on delete restrict,
  patient_id uuid not null references public.patients(id) on delete restrict,
  restriction_type public.nutrition_restriction_type not null default 'custom',
  item_name text not null,
  instructions text,
  severity public.nutrition_severity not null default 'medium',
  created_by uuid references public.user_profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create table public.nutrition_notes (
  id uuid primary key default gen_random_uuid(),
  center_id uuid not null references public.centers(id) on delete restrict,
  patient_id uuid not null references public.patients(id) on delete restrict,
  diet_plan_id uuid references public.nutrition_diet_plans(id) on delete set null,
  note text not null,
  created_by uuid references public.user_profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create unique index patient_nutrition_profiles_one_active
  on public.patient_nutrition_profiles (center_id, patient_id)
  where deleted_at is null;
create unique index nutrition_diet_plans_one_active
  on public.nutrition_diet_plans (center_id, patient_id)
  where status = 'active';
create index on public.nutrition_diet_plans (center_id, patient_id, created_at desc);
create index on public.nutrition_meal_items (center_id, diet_plan_id, sort_order);
create index on public.nutrition_restrictions (center_id, patient_id) where deleted_at is null;
create index on public.nutrition_notes (center_id, patient_id, created_at desc) where deleted_at is null;

create or replace function public.role_can_read()
returns boolean language sql stable as $$ select public.current_role()::text in ('center_admin','doctor','technician','nutritionist') $$;

create or replace function public.role_can_clinical_note()
returns boolean language sql stable as $$ select public.current_role()::text in ('center_admin','doctor','technician','nutritionist') $$;

create or replace function public.role_can_manage_nutrition()
returns boolean language sql stable as $$ select public.current_role()::text in ('center_admin','doctor','nutritionist') $$;

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
  elsif tg_table_name = 'patient_nutrition_profiles' then
    perform public.assert_same_center('patients', new.patient_id, 'patient_id', new.center_id);
    perform public.assert_same_center('user_profiles', new.created_by, 'created_by', new.center_id);
    perform public.assert_same_center('user_profiles', new.updated_by, 'updated_by', new.center_id);
  elsif tg_table_name = 'nutrition_diet_plans' then
    perform public.assert_same_center('patients', new.patient_id, 'patient_id', new.center_id);
    perform public.assert_same_center('patient_nutrition_profiles', new.nutrition_profile_id, 'nutrition_profile_id', new.center_id);
    perform public.assert_same_center('user_profiles', new.created_by, 'created_by', new.center_id);
    perform public.assert_same_center('user_profiles', new.updated_by, 'updated_by', new.center_id);
    perform public.assert_same_center('user_profiles', new.reviewed_by, 'reviewed_by', new.center_id);
    perform public.assert_same_patient('patient_nutrition_profiles', new.nutrition_profile_id, 'nutrition_profile_id', new.patient_id);
  elsif tg_table_name = 'nutrition_meal_items' then
    perform public.assert_same_center('nutrition_diet_plans', new.diet_plan_id, 'diet_plan_id', new.center_id);
  elsif tg_table_name = 'nutrition_restrictions' then
    perform public.assert_same_center('patients', new.patient_id, 'patient_id', new.center_id);
    perform public.assert_same_center('user_profiles', new.created_by, 'created_by', new.center_id);
  elsif tg_table_name = 'nutrition_notes' then
    perform public.assert_same_center('patients', new.patient_id, 'patient_id', new.center_id);
    perform public.assert_same_center('nutrition_diet_plans', new.diet_plan_id, 'diet_plan_id', new.center_id);
    perform public.assert_same_center('user_profiles', new.created_by, 'created_by', new.center_id);
    perform public.assert_same_patient('nutrition_diet_plans', new.diet_plan_id, 'diet_plan_id', new.patient_id);
  elsif tg_table_name = 'audit_logs' then
    perform public.assert_same_center('user_profiles', new.user_id, 'user_id', new.center_id);
  end if;

  return new;
end;
$$;

create or replace function public.archive_previous_active_nutrition_plan()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'active' and (tg_op = 'INSERT' or old.status is distinct from 'active') then
    update public.nutrition_diet_plans
      set status = 'archived',
          archived_at = coalesce(archived_at, now()),
          updated_at = now()
      where center_id = new.center_id
        and patient_id = new.patient_id
        and id <> new.id
        and status = 'active';
  end if;
  if new.status = 'archived' and new.archived_at is null then
    new.archived_at = now();
  end if;
  return new;
end;
$$;

do $$
declare t text;
begin
  foreach t in array array['patient_nutrition_profiles','nutrition_diet_plans','nutrition_meal_items','nutrition_restrictions','nutrition_notes'] loop
    execute format('create trigger %I_updated_at before update on public.%I for each row execute function public.set_updated_at()', t, t);
    execute format('create trigger %I_set_tenant before insert on public.%I for each row execute function public.set_tenant_columns()', t, t);
    execute format('create trigger %I_validate_tenant_references before insert or update on public.%I for each row execute function public.validate_tenant_references()', t, t);
    execute format('create trigger %I_audit after insert or update or delete on public.%I for each row execute function public.audit_row_change()', t, t);
  end loop;
end $$;

create trigger nutrition_diet_plans_archive_previous
before insert or update on public.nutrition_diet_plans
for each row execute function public.archive_previous_active_nutrition_plan();

alter table public.patient_nutrition_profiles enable row level security;
alter table public.nutrition_diet_plans enable row level security;
alter table public.nutrition_meal_items enable row level security;
alter table public.nutrition_restrictions enable row level security;
alter table public.nutrition_notes enable row level security;

create policy patient_nutrition_profiles_center_select on public.patient_nutrition_profiles
for select using (center_id = public.current_center_id() and public.role_can_read());
create policy nutrition_diet_plans_center_select on public.nutrition_diet_plans
for select using (center_id = public.current_center_id() and public.role_can_read());
create policy nutrition_meal_items_center_select on public.nutrition_meal_items
for select using (center_id = public.current_center_id() and public.role_can_read());
create policy nutrition_restrictions_center_select on public.nutrition_restrictions
for select using (center_id = public.current_center_id() and public.role_can_read());
create policy nutrition_notes_center_select on public.nutrition_notes
for select using (center_id = public.current_center_id() and public.role_can_read());

create policy patient_nutrition_profiles_write on public.patient_nutrition_profiles
for all using (center_id = public.current_center_id() and public.role_can_manage_nutrition())
with check (center_id = public.current_center_id() and public.role_can_manage_nutrition());
create policy nutrition_diet_plans_write on public.nutrition_diet_plans
for all using (center_id = public.current_center_id() and public.role_can_manage_nutrition())
with check (center_id = public.current_center_id() and public.role_can_manage_nutrition());
create policy nutrition_meal_items_write on public.nutrition_meal_items
for all using (center_id = public.current_center_id() and public.role_can_manage_nutrition())
with check (center_id = public.current_center_id() and public.role_can_manage_nutrition());
create policy nutrition_restrictions_write on public.nutrition_restrictions
for all using (center_id = public.current_center_id() and public.role_can_manage_nutrition())
with check (center_id = public.current_center_id() and public.role_can_manage_nutrition());
create policy nutrition_notes_insert on public.nutrition_notes
for insert with check (center_id = public.current_center_id() and public.role_can_manage_nutrition());
create policy nutrition_notes_update on public.nutrition_notes
for update using (center_id = public.current_center_id() and created_by = public.current_profile_id())
with check (center_id = public.current_center_id());

drop policy if exists storage_insert_center_files on storage.objects;
drop policy if exists storage_update_center_files on storage.objects;
create policy storage_insert_center_files on storage.objects for insert
with check (
  bucket_id = 'patient-attachments'
  and (storage.foldername(name))[1] = public.current_center_id()::text
  and public.current_role()::text in ('center_admin','technician','nutritionist')
);
create policy storage_update_center_files on storage.objects for update
using (bucket_id = 'patient-attachments' and (storage.foldername(name))[1] = public.current_center_id()::text and public.current_role()::text in ('center_admin','technician','nutritionist'));
