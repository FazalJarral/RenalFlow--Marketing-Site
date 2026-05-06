-- Lab matrix reporting module.
-- Additive migration: preserves lab_reports and lab_report_items, then mirrors
-- legacy item rows into matrix cells for compatibility.

alter type public.lab_item_status add value if not exists 'positive';
alter type public.lab_item_status add value if not exists 'negative';
alter type public.lab_item_status add value if not exists 'borderline';

alter type public.audit_action add value if not exists 'archive';
alter type public.audit_action add value if not exists 'complete';
alter type public.audit_action add value if not exists 'review';

do $$ begin
  create type public.lab_report_status as enum ('draft', 'completed', 'reviewed', 'archived');
exception when duplicate_object then null;
end $$;

do $$ begin
  create type public.lab_row_type as enum ('test', 'section_header', 'comment');
exception when duplicate_object then null;
end $$;

do $$ begin
  create type public.lab_result_type as enum ('numeric', 'text', 'qualitative', 'mixed');
exception when duplicate_object then null;
end $$;

alter table public.lab_reports add column if not exists report_title text;
alter table public.lab_reports add column if not exists acc_no text;
alter table public.lab_reports add column if not exists external_patient_id text;
alter table public.lab_reports add column if not exists doctor_name text;
alter table public.lab_reports add column if not exists specimen_received_at timestamptz;
alter table public.lab_reports add column if not exists status public.lab_report_status not null default 'completed';
alter table public.lab_reports add column if not exists urgent_flag boolean not null default false;
alter table public.lab_reports add column if not exists urgent_message text;
alter table public.lab_reports add column if not exists updated_by uuid references public.user_profiles(id);

alter table public.attachments add column if not exists attachment_context text;

create table if not exists public.lab_panels (
  id uuid primary key default gen_random_uuid(),
  center_id uuid not null references public.centers(id) on delete cascade,
  name text not null,
  code text not null,
  description text,
  category text not null default 'custom',
  is_active boolean not null default true,
  sort_order int not null default 0,
  created_by uuid references public.user_profiles(id),
  updated_by uuid references public.user_profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  unique (center_id, code)
);

create table if not exists public.lab_panel_tests (
  id uuid primary key default gen_random_uuid(),
  center_id uuid not null references public.centers(id) on delete cascade,
  panel_id uuid not null references public.lab_panels(id) on delete cascade,
  test_template_id uuid references public.lab_test_templates(id),
  test_name text not null,
  row_type public.lab_row_type not null default 'test',
  section_name text,
  default_unit text,
  allowed_units text[],
  standard_unit text,
  reference_range_text text,
  normal_min numeric,
  normal_max numeric,
  critical_low numeric,
  critical_high numeric,
  result_type public.lab_result_type not null default 'numeric',
  sort_order int not null default 0,
  is_required boolean not null default false,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create table if not exists public.lab_report_panels (
  id uuid primary key default gen_random_uuid(),
  center_id uuid not null references public.centers(id) on delete restrict,
  lab_report_id uuid not null references public.lab_reports(id) on delete cascade,
  panel_id uuid references public.lab_panels(id),
  panel_name_snapshot text not null,
  panel_code_snapshot text,
  sort_order int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create table if not exists public.lab_report_date_columns (
  id uuid primary key default gen_random_uuid(),
  center_id uuid not null references public.centers(id) on delete restrict,
  lab_report_id uuid not null references public.lab_reports(id) on delete cascade,
  result_date date not null,
  label text,
  sort_order int not null default 0,
  is_primary boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create unique index if not exists lab_report_one_primary_date
on public.lab_report_date_columns(lab_report_id)
where is_primary and deleted_at is null;

create table if not exists public.lab_result_cells (
  id uuid primary key default gen_random_uuid(),
  center_id uuid not null references public.centers(id) on delete restrict,
  lab_report_id uuid not null references public.lab_reports(id) on delete cascade,
  lab_report_panel_id uuid not null references public.lab_report_panels(id) on delete cascade,
  lab_report_date_column_id uuid not null references public.lab_report_date_columns(id) on delete cascade,
  panel_test_id uuid references public.lab_panel_tests(id),
  test_template_id uuid references public.lab_test_templates(id),
  test_name_snapshot text not null,
  row_type public.lab_row_type not null default 'test',
  result_type public.lab_result_type not null default 'numeric',
  raw_value text,
  numeric_value numeric,
  text_value text,
  qualitative_value text,
  unit text,
  standardized_value numeric,
  standard_unit_snapshot text,
  reference_range_text_snapshot text,
  normal_min_snapshot numeric,
  normal_max_snapshot numeric,
  critical_low_snapshot numeric,
  critical_high_snapshot numeric,
  status public.lab_item_status not null default 'unknown',
  interpretation text,
  notes text,
  sort_order int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create index if not exists lab_panels_center_active_idx on public.lab_panels(center_id, sort_order) where deleted_at is null;
create index if not exists lab_panel_tests_panel_idx on public.lab_panel_tests(center_id, panel_id, sort_order) where deleted_at is null;
create unique index if not exists lab_panel_tests_row_unique_idx on public.lab_panel_tests(center_id, panel_id, test_name, sort_order);
create index if not exists lab_report_panels_report_idx on public.lab_report_panels(center_id, lab_report_id, sort_order) where deleted_at is null;
create index if not exists lab_report_date_columns_report_idx on public.lab_report_date_columns(center_id, lab_report_id, sort_order) where deleted_at is null;
create index if not exists lab_result_cells_patient_idx on public.lab_result_cells(center_id, test_name_snapshot, test_template_id) where deleted_at is null;
create index if not exists lab_result_cells_report_idx on public.lab_result_cells(center_id, lab_report_id, lab_report_panel_id, lab_report_date_column_id) where deleted_at is null;

create or replace function public.set_lab_result_cell_status()
returns trigger language plpgsql as $$
declare
  comparable numeric;
begin
  comparable = coalesce(new.standardized_value, new.numeric_value);
  if new.row_type <> 'test' or comparable is null then
    new.status = coalesce(new.status, 'unknown'::public.lab_item_status);
  elsif new.critical_low_snapshot is not null and comparable <= new.critical_low_snapshot then
    new.status = 'critical_low'::public.lab_item_status;
  elsif new.critical_high_snapshot is not null and comparable >= new.critical_high_snapshot then
    new.status = 'critical_high'::public.lab_item_status;
  elsif new.normal_min_snapshot is not null and comparable < new.normal_min_snapshot then
    new.status = 'low'::public.lab_item_status;
  elsif new.normal_max_snapshot is not null and comparable > new.normal_max_snapshot then
    new.status = 'high'::public.lab_item_status;
  elsif new.normal_min_snapshot is null and new.normal_max_snapshot is null then
    new.status = coalesce(new.status, 'unknown'::public.lab_item_status);
  else
    new.status = 'normal'::public.lab_item_status;
  end if;
  return new;
end;
$$;

create or replace function public.validate_lab_matrix_completed()
returns trigger language plpgsql as $$
declare
  missing_required int;
  missing_numeric int;
  panel_count int;
  primary_count int;
begin
  if new.status <> 'completed' and new.status <> 'reviewed' then
    return new;
  end if;

  select count(*) into panel_count from public.lab_report_panels
  where lab_report_id = new.id and deleted_at is null;
  if panel_count = 0 then
    raise exception 'Completed lab matrix reports require at least one panel.';
  end if;

  select count(*) into primary_count from public.lab_report_date_columns
  where lab_report_id = new.id and is_primary and deleted_at is null;
  if primary_count <> 1 then
    raise exception 'Completed lab matrix reports require exactly one primary date column.';
  end if;

  select count(*) into missing_required
  from public.lab_result_cells c
  join public.lab_report_date_columns d on d.id = c.lab_report_date_column_id
  join public.lab_panel_tests t on t.id = c.panel_test_id
  where c.lab_report_id = new.id
    and d.is_primary
    and t.is_required
    and c.row_type = 'test'
    and c.deleted_at is null
    and nullif(trim(coalesce(c.raw_value, c.text_value, c.qualitative_value, c.numeric_value::text, '')), '') is null;
  if missing_required > 0 then
    raise exception 'Completed lab matrix reports have missing required primary-date results.';
  end if;

  select count(*) into missing_numeric
  from public.lab_result_cells c
  join public.lab_report_date_columns d on d.id = c.lab_report_date_column_id
  where c.lab_report_id = new.id
    and d.is_primary
    and c.row_type = 'test'
    and c.result_type in ('numeric', 'mixed')
    and nullif(trim(coalesce(c.raw_value, '')), '') is not null
    and c.numeric_value is null
    and c.deleted_at is null;
  if missing_numeric > 0 then
    raise exception 'Completed lab matrix reports contain numeric rows that could not be parsed.';
  end if;

  return new;
end;
$$;

create or replace function public.audit_lab_report_status_event()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  status_action text;
begin
  if old.status is not distinct from new.status then
    return new;
  end if;

  status_action = case new.status::text
    when 'completed' then 'complete'
    when 'reviewed' then 'review'
    when 'archived' then 'archive'
    else null
  end;

  if status_action is not null then
    insert into public.audit_logs(center_id, user_id, entity_type, entity_id, action, before_data, after_data)
    values (new.center_id, public.current_profile_id(), 'lab_reports', new.id, status_action::public.audit_action, to_jsonb(old), to_jsonb(new));
  end if;

  return new;
end;
$$;

create or replace function public.validate_tenant_references()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_table_name = 'patients' then
    perform public.assert_same_center('user_profiles', new.assigned_doctor_id, 'assigned_doctor_id', new.center_id);
  elsif tg_table_name = 'lab_unit_conversions' then
    perform public.assert_same_center('lab_test_templates', new.test_template_id, 'test_template_id', new.center_id);
  elsif tg_table_name = 'lab_panels' then
    perform public.assert_same_center('user_profiles', new.created_by, 'created_by', new.center_id);
    perform public.assert_same_center('user_profiles', new.updated_by, 'updated_by', new.center_id);
  elsif tg_table_name = 'lab_panel_tests' then
    perform public.assert_same_center('lab_panels', new.panel_id, 'panel_id', new.center_id);
    perform public.assert_same_center('lab_test_templates', new.test_template_id, 'test_template_id', new.center_id);
  elsif tg_table_name = 'lab_reports' then
    perform public.assert_same_center('patients', new.patient_id, 'patient_id', new.center_id);
    perform public.assert_same_center('user_profiles', new.created_by, 'created_by', new.center_id);
    perform public.assert_same_center('user_profiles', new.updated_by, 'updated_by', new.center_id);
    perform public.assert_same_center('user_profiles', new.reviewed_by, 'reviewed_by', new.center_id);
  elsif tg_table_name = 'lab_report_items' then
    perform public.assert_same_center('lab_reports', new.lab_report_id, 'lab_report_id', new.center_id);
    perform public.assert_same_center('patients', new.patient_id, 'patient_id', new.center_id);
    perform public.assert_same_center('lab_test_templates', new.test_template_id, 'test_template_id', new.center_id);
    perform public.assert_same_patient('lab_reports', new.lab_report_id, 'lab_report_id', new.patient_id);
  elsif tg_table_name = 'lab_report_panels' then
    perform public.assert_same_center('lab_reports', new.lab_report_id, 'lab_report_id', new.center_id);
    perform public.assert_same_center('lab_panels', new.panel_id, 'panel_id', new.center_id);
  elsif tg_table_name = 'lab_report_date_columns' then
    perform public.assert_same_center('lab_reports', new.lab_report_id, 'lab_report_id', new.center_id);
  elsif tg_table_name = 'lab_result_cells' then
    perform public.assert_same_center('lab_reports', new.lab_report_id, 'lab_report_id', new.center_id);
    perform public.assert_same_center('lab_report_panels', new.lab_report_panel_id, 'lab_report_panel_id', new.center_id);
    perform public.assert_same_center('lab_report_date_columns', new.lab_report_date_column_id, 'lab_report_date_column_id', new.center_id);
    perform public.assert_same_center('lab_panel_tests', new.panel_test_id, 'panel_test_id', new.center_id);
    perform public.assert_same_center('lab_test_templates', new.test_template_id, 'test_template_id', new.center_id);
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

do $$
declare t text;
begin
  foreach t in array array['lab_panels','lab_panel_tests','lab_reports','lab_report_panels','lab_report_date_columns','lab_result_cells'] loop
    execute format('drop trigger if exists %I_updated_at on public.%I', t, t);
    execute format('create trigger %I_updated_at before update on public.%I for each row execute function public.set_updated_at()', t, t);
  end loop;

  foreach t in array array['lab_panels','lab_panel_tests','lab_report_panels','lab_report_date_columns','lab_result_cells'] loop
    execute format('drop trigger if exists %I_set_tenant on public.%I', t, t);
    execute format('create trigger %I_set_tenant before insert on public.%I for each row execute function public.set_tenant_columns()', t, t);
  end loop;

  foreach t in array array['lab_panels','lab_panel_tests','lab_reports','lab_report_panels','lab_report_date_columns','lab_result_cells','attachments'] loop
    execute format('drop trigger if exists %I_validate_tenant_references on public.%I', t, t);
    execute format('create trigger %I_validate_tenant_references before insert or update on public.%I for each row execute function public.validate_tenant_references()', t, t);
  end loop;

  foreach t in array array['lab_panels','lab_panel_tests','lab_report_panels','lab_report_date_columns','lab_result_cells'] loop
    execute format('drop trigger if exists %I_audit on public.%I', t, t);
    execute format('create trigger %I_audit after insert or update or delete on public.%I for each row execute function public.audit_row_change()', t, t);
  end loop;
end $$;

drop trigger if exists lab_result_cells_status on public.lab_result_cells;
create trigger lab_result_cells_status before insert or update on public.lab_result_cells
for each row execute function public.set_lab_result_cell_status();

drop trigger if exists lab_reports_validate_completed on public.lab_reports;
create trigger lab_reports_validate_completed before update on public.lab_reports
for each row execute function public.validate_lab_matrix_completed();

drop trigger if exists lab_reports_status_event_audit on public.lab_reports;
create trigger lab_reports_status_event_audit after update on public.lab_reports
for each row execute function public.audit_lab_report_status_event();

alter table public.lab_panels enable row level security;
alter table public.lab_panel_tests enable row level security;
alter table public.lab_report_panels enable row level security;
alter table public.lab_report_date_columns enable row level security;
alter table public.lab_result_cells enable row level security;

do $$
declare t text;
begin
  foreach t in array array['lab_panels','lab_panel_tests','lab_report_panels','lab_report_date_columns','lab_result_cells'] loop
    execute format('drop policy if exists %I_center_select on public.%I', t, t);
    execute format('create policy %I_center_select on public.%I for select using (center_id = public.current_center_id() and public.role_can_read())', t, t);
  end loop;

  foreach t in array array['lab_panels','lab_panel_tests'] loop
    execute format('drop policy if exists %I_admin_insert on public.%I', t, t);
    execute format('drop policy if exists %I_admin_update on public.%I', t, t);
    execute format('drop policy if exists %I_admin_delete on public.%I', t, t);
    execute format('create policy %I_admin_insert on public.%I for insert with check (center_id = public.current_center_id() and public.current_role() = ''center_admin'')', t, t);
    execute format('create policy %I_admin_update on public.%I for update using (center_id = public.current_center_id() and public.current_role() = ''center_admin'') with check (center_id = public.current_center_id())', t, t);
    execute format('create policy %I_admin_delete on public.%I for delete using (center_id = public.current_center_id() and public.current_role() = ''center_admin'')', t, t);
  end loop;

  foreach t in array array['lab_report_panels','lab_report_date_columns','lab_result_cells'] loop
    execute format('drop policy if exists %I_ops_insert on public.%I', t, t);
    execute format('drop policy if exists %I_ops_update on public.%I', t, t);
    execute format('create policy %I_ops_insert on public.%I for insert with check (center_id = public.current_center_id() and public.role_can_operate())', t, t);
    execute format('create policy %I_ops_update on public.%I for update using (center_id = public.current_center_id() and public.role_can_operate()) with check (center_id = public.current_center_id())', t, t);
  end loop;
end $$;

create or replace function public.seed_default_lab_matrix_panels(target_center_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  -- Default reference ranges are seeds only and must be verified/customized by each dialysis center.
  with panels(name, code, description, category, sort_order) as (
    values
    ('CP / CBC','CP_CBC','Complete picture / complete blood count','blood_cp_cbc',10),
    ('RFT - Renal Function Tests','RFT','Renal function tests','rft',20),
    ('LFT - Liver Function Tests','LFT','Liver function tests','lft',30),
    ('Serum Electrolytes','ELECTROLYTES','Serum electrolyte panel','serum_electrolytes',40),
    ('Minerals / Iron / Inflammation','MIN_IRON','Minerals, iron and inflammation markers','iron_profile',50),
    ('Special Chemistry','SPECIAL_CHEM','Special chemistry tests','special_chemistry',60),
    ('Hepatitis Profile','HEPATITIS','Hepatitis screening profile','hepatitis_profile',70),
    ('Custom','CUSTOM','Center-defined custom panel','custom',80)
  )
  insert into public.lab_panels(center_id, name, code, description, category, sort_order)
  select target_center_id, name, code, description, category, sort_order from panels
  on conflict (center_id, code) do update set
    name = excluded.name,
    description = excluded.description,
    category = excluded.category,
    sort_order = excluded.sort_order,
    updated_at = now();

  insert into public.lab_panel_tests(center_id, panel_id, test_name, row_type, section_name, default_unit, allowed_units, standard_unit, reference_range_text, normal_min, normal_max, result_type, sort_order, is_required)
  select target_center_id, p.id, x.test_name, x.row_type::public.lab_row_type, x.section_name, x.default_unit, x.allowed_units, x.standard_unit, x.reference_range_text, x.normal_min, x.normal_max, x.result_type::public.lab_result_type, x.sort_order, x.is_required
  from public.lab_panels p
  join (
    values
    ('CP_CBC','Hematology','section_header',null,null,null,null,null,null,null,'text',10,false),
    ('CP_CBC','WBC Count','test','Hematology','/mm3',array['/mm3'],'/mm3','4,000 - 10,000',4000,10000,'numeric',20,true),
    ('CP_CBC','RBC Count','test','Hematology','mil/mm3',array['mil/mm3'],'mil/mm3','4.5 - 5.5',4.5,5.5,'numeric',30,false),
    ('CP_CBC','Hemoglobin','test','Hematology','g/dL',array['g/dL'],'g/dL','13.0 - 17.0',13,17,'numeric',40,true),
    ('CP_CBC','Hematocrit','test','Hematology','%',array['%'],'%','40 - 50',40,50,'numeric',50,false),
    ('CP_CBC','MCV','test','Hematology','fL',array['fL'],'fL','83 - 101',83,101,'numeric',60,false),
    ('CP_CBC','MCH','test','Hematology','pg',array['pg'],'pg','27 - 32',27,32,'numeric',70,false),
    ('CP_CBC','MCHC','test','Hematology','g/dL',array['g/dL'],'g/dL','31.5 - 34.5',31.5,34.5,'numeric',80,false),
    ('CP_CBC','RDW-CV','test','Hematology','%',array['%'],'%','11 - 16',11,16,'numeric',90,false),
    ('CP_CBC','Platelets','test','Hematology','/mm3',array['/mm3'],'/mm3','150,000 - 410,000',150000,410000,'numeric',100,true),
    ('CP_CBC','Differential Count','section_header',null,null,null,null,null,null,null,'text',110,false),
    ('CP_CBC','Neutrophils','test','Differential Count','%',array['%'],'%','40 - 70',40,70,'numeric',120,false),
    ('CP_CBC','Lymphocytes','test','Differential Count','%',array['%'],'%','25 - 45',25,45,'numeric',130,false),
    ('CP_CBC','Monocytes','test','Differential Count','%',array['%'],'%','2 - 12',2,12,'numeric',140,false),
    ('CP_CBC','Eosinophils','test','Differential Count','%',array['%'],'%','1 - 5',1,5,'numeric',150,false),
    ('CP_CBC','Basophils','test','Differential Count','%',array['%'],'%','0 - 1',0,1,'numeric',160,false),
    ('CP_CBC','Bands','test','Differential Count','%',array['%'],'%','0 - 3',0,3,'numeric',170,false),
    ('RFT','Blood Urea','test',null,'mg/dL',array['mg/dL'],'mg/dL','10 - 50',10,50,'numeric',10,true),
    ('RFT','Serum Creatinine','test',null,'mg/dL',array['mg/dL','umol/L'],'mg/dL','0.4 - 1.3',0.4,1.3,'numeric',20,true),
    ('RFT','Uric Acid','test',null,'mg/dL',array['mg/dL'],'mg/dL','3.7 - 7.7',3.7,7.7,'numeric',30,false),
    ('RFT','BUN','test',null,'mg/dL',array['mg/dL'],'mg/dL','5 - 24',5,24,'numeric',40,false),
    ('RFT','eGFR','test',null,'mL/min/1.73m^2',array['mL/min/1.73m^2'],'mL/min/1.73m^2','> 60',60,null,'numeric',50,false),
    ('LFT','Direct Bilirubin','test',null,'mg/dL',array['mg/dL'],'mg/dL','0.0 - 0.3',0,0.3,'numeric',10,false),
    ('LFT','Indirect Bilirubin','test',null,'mg/dL',array['mg/dL'],'mg/dL','0.1 - 0.8',0.1,0.8,'numeric',20,false),
    ('LFT','Total Bilirubin','test',null,'mg/dL',array['mg/dL'],'mg/dL','0.2 - 1.1',0.2,1.1,'numeric',30,false),
    ('LFT','SGOT (AST)','test',null,'IU/L',array['IU/L'],'IU/L','9 - 40',9,40,'numeric',40,false),
    ('LFT','SGPT (ALT)','test',null,'IU/L',array['IU/L'],'IU/L','5 - 50',5,50,'numeric',50,false),
    ('LFT','Alkaline Phosphatase','test',null,'IU/L',array['IU/L'],'IU/L','56 - 167',56,167,'numeric',60,false),
    ('LFT','Gamma GT','test',null,'IU/L',array['IU/L'],'IU/L','< 69',null,69,'numeric',70,false),
    ('ELECTROLYTES','Sodium','test',null,'mmol/L',array['mmol/L'],'mmol/L','136 - 145',136,145,'numeric',10,true),
    ('ELECTROLYTES','Potassium','test',null,'mmol/L',array['mmol/L'],'mmol/L','3.5 - 5.3',3.5,5.3,'numeric',20,true),
    ('ELECTROLYTES','Chloride','test',null,'mmol/L',array['mmol/L'],'mmol/L','98 - 107',98,107,'numeric',30,false),
    ('ELECTROLYTES','Bicarbonate','test',null,'mmol/L',array['mmol/L'],'mmol/L','23 - 31',23,31,'numeric',40,false),
    ('ELECTROLYTES','Anion Gap','test',null,'mmol/L',array['mmol/L'],'mmol/L','8 - 16',8,16,'numeric',50,false),
    ('MIN_IRON','Calcium','test',null,'mg/dL',array['mg/dL'],'mg/dL','8.4 - 10.2',8.4,10.2,'numeric',10,false),
    ('MIN_IRON','C.R.P.','test',null,'mg/L',array['mg/L'],'mg/L','< 5.0 Negative / 5.0 and above Positive',null,5,'mixed',20,false),
    ('MIN_IRON','TIBC','test',null,'ug/dL',array['ug/dL'],'ug/dL','250 - 450',250,450,'numeric',30,false),
    ('MIN_IRON','Phosphorous','test',null,'mg/dL',array['mg/dL'],'mg/dL','2.4 - 4.7',2.4,4.7,'numeric',40,false),
    ('MIN_IRON','Iron','test',null,'ug/dL',array['ug/dL'],'ug/dL','65 - 170',65,170,'numeric',50,false),
    ('MIN_IRON','Albumin','test',null,'g/dL',array['g/dL'],'g/dL','3.5 - 5.2',3.5,5.2,'numeric',60,false),
    ('SPECIAL_CHEM','Parathyroid Hormone (PTH) - Intact','test',null,'pg/mL',array['pg/mL'],'pg/mL','15 - 68',15,68,'numeric',10,false),
    ('SPECIAL_CHEM','Ferritin','test',null,'ng/mL',array['ng/mL'],'ng/mL','20 - 275',20,275,'numeric',20,false),
    ('HEPATITIS','Hep Bs Ag (Qualitative)','test',null,null,array['result'],null,'Non-Reactive',null,null,'qualitative',10,true),
    ('HEPATITIS','Hep Bs Ag Patient S/CO','test',null,'S/CO',array['S/CO'],'S/CO','<1.0 Non-Reactive / 1.0 - 5.0 Borderline / >5.0 Reactive',null,1,'mixed',20,false),
    ('HEPATITIS','HCV Ab','test',null,null,array['result'],null,'Non-Reactive',null,null,'qualitative',30,true),
    ('HEPATITIS','HCV Ab Patient S/CO','test',null,'S/CO',array['S/CO'],'S/CO','<1.0 Non-Reactive / 1.0 - 6.0 Borderline / >6.0 Reactive',null,1,'mixed',40,false)
  ) as x(code, test_name, row_type, section_name, default_unit, allowed_units, standard_unit, reference_range_text, normal_min, normal_max, result_type, sort_order, is_required)
  on p.code = x.code
  where p.center_id = target_center_id
  on conflict (center_id, panel_id, test_name, sort_order) do update set
    row_type = excluded.row_type,
    section_name = excluded.section_name,
    default_unit = excluded.default_unit,
    allowed_units = excluded.allowed_units,
    standard_unit = excluded.standard_unit,
    reference_range_text = excluded.reference_range_text,
    normal_min = excluded.normal_min,
    normal_max = excluded.normal_max,
    result_type = excluded.result_type,
    is_required = excluded.is_required,
    is_active = true,
    updated_at = now();
end;
$$;

do $$
declare c record;
begin
  alter table public.lab_panels disable trigger user;
  alter table public.lab_panel_tests disable trigger user;

  for c in select id from public.centers loop
    perform public.seed_default_lab_matrix_panels(c.id);
  end loop;

  alter table public.lab_panel_tests enable trigger user;
  alter table public.lab_panels enable trigger user;
end $$;

-- Existing lab_report_items are intentionally left untouched.
-- The app still reads them for individual report fallback display, while all
-- newly-created reports use the matrix tables above. A legacy backfill can be
-- run later from an authenticated/admin maintenance path if production data
-- needs to be converted.
