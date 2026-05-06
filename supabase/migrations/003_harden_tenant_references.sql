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

do $$
declare t text;
begin
  foreach t in array array['patients','lab_unit_conversions','lab_reports','lab_report_items','dialysis_sessions','session_vitals','vaccinations','injections','schedules','notes','attachments','audit_logs'] loop
    execute format('drop trigger if exists %I_validate_tenant_references on public.%I', t, t);
    execute format('create trigger %I_validate_tenant_references before insert or update on public.%I for each row execute function public.validate_tenant_references()', t, t);
  end loop;
end $$;

drop policy if exists lab_reports_ops_update on public.lab_reports;
drop policy if exists lab_report_items_ops_update on public.lab_report_items;
drop policy if exists dialysis_sessions_ops_update on public.dialysis_sessions;
drop policy if exists session_vitals_ops_update on public.session_vitals;
drop policy if exists vaccinations_ops_update on public.vaccinations;
drop policy if exists injections_ops_update on public.injections;
drop policy if exists attachments_ops_update on public.attachments;

create policy lab_reports_ops_update on public.lab_reports for update
using (center_id = public.current_center_id() and public.role_can_operate())
with check (center_id = public.current_center_id());
create policy lab_report_items_ops_update on public.lab_report_items for update
using (center_id = public.current_center_id() and public.role_can_operate())
with check (center_id = public.current_center_id());
create policy dialysis_sessions_ops_update on public.dialysis_sessions for update
using (center_id = public.current_center_id() and public.role_can_operate())
with check (center_id = public.current_center_id());
create policy session_vitals_ops_update on public.session_vitals for update
using (center_id = public.current_center_id() and public.role_can_operate())
with check (center_id = public.current_center_id());
create policy vaccinations_ops_update on public.vaccinations for update
using (center_id = public.current_center_id() and public.role_can_operate())
with check (center_id = public.current_center_id());
create policy injections_ops_update on public.injections for update
using (center_id = public.current_center_id() and public.role_can_operate())
with check (center_id = public.current_center_id());
create policy attachments_ops_update on public.attachments for update
using (center_id = public.current_center_id() and public.role_can_operate())
with check (center_id = public.current_center_id());
