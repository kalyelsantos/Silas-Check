-- SILAS WorkTime 2.11: notificações internas e pedidos de autorização de dispositivos.
-- Aplicar no SQL Editor do projeto SILAS CHECK, depois de rever em staging.
-- Não modifica nem remove dados existentes. As tabelas novas usam RLS.

create table if not exists public.worktime_alert_preferences (
  admin_profile_id uuid primary key references public.profiles(id) on delete cascade,
  enabled boolean not null default false,
  browser_enabled boolean not null default false,
  absence_enabled boolean not null default true,
  late_enabled boolean not null default true,
  recurring_late_enabled boolean not null default true,
  devices_enabled boolean not null default true,
  missing_entry_enabled boolean not null default true,
  recurring_late_threshold integer not null default 3 check (recurring_late_threshold between 2 and 10),
  updated_at timestamptz not null default now()
);

create table if not exists public.worktime_alerts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  event_key text not null,
  kind text not null check (kind in ('device_pending','device_new_admin','late','recurring_late','missing_entry','possible_absence')),
  employee_id uuid references public.profiles(id),
  title text not null,
  body text not null,
  work_date date,
  created_at timestamptz not null default now(),
  unique(organization_id,event_key)
);
create index if not exists worktime_alerts_org_recent on public.worktime_alerts(organization_id,created_at desc);
create index if not exists worktime_alerts_late on public.worktime_alerts(organization_id,employee_id,kind,work_date);

create table if not exists public.worktime_alert_reads (
  alert_id uuid not null references public.worktime_alerts(id) on delete cascade,
  admin_profile_id uuid not null references public.profiles(id) on delete cascade,
  read_at timestamptz not null default now(),
  primary key(alert_id,admin_profile_id)
);

create table if not exists public.worktime_device_authorizations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  profile_id uuid not null references public.profiles(id),
  device_id uuid not null,
  label text not null,
  user_agent text,
  status text not null default 'pending' check (status in ('pending','approved','rejected','revoked')),
  requested_at timestamptz not null default now(),
  decided_at timestamptz,
  decided_by uuid references public.profiles(id),
  last_seen_at timestamptz,
  unique (profile_id,device_id)
);
create index if not exists worktime_devices_org_status on public.worktime_device_authorizations(organization_id,status,requested_at desc);

alter table public.worktime_alert_preferences enable row level security;
alter table public.worktime_alerts enable row level security;
alter table public.worktime_alert_reads enable row level security;
alter table public.worktime_device_authorizations enable row level security;

-- Retirar escrita direta; mutações apenas através de funções com validação de papel e organização.
revoke all on public.worktime_alert_preferences, public.worktime_alerts, public.worktime_alert_reads, public.worktime_device_authorizations from anon, authenticated;
grant select on public.worktime_alert_preferences,public.worktime_alerts,public.worktime_alert_reads,public.worktime_device_authorizations to authenticated;

-- As políticas SELECT só permitem ver o próprio ou ver dados administrativos dentro da organização.
drop policy if exists wt_alert_pref_read on public.worktime_alert_preferences;
create policy wt_alert_pref_read on public.worktime_alert_preferences for select to authenticated using (
  exists(select 1 from public.profiles p where p.id=admin_profile_id and p.auth_user_id=(select auth.uid()) and p.active and p.role='admin')
);
drop policy if exists wt_alert_read on public.worktime_alerts;
create policy wt_alert_read on public.worktime_alerts for select to authenticated using (
  exists(select 1 from public.profiles p where p.auth_user_id=(select auth.uid()) and p.active and p.role='admin' and p.organization_id=organization_id)
);
drop policy if exists wt_alert_receipt_read on public.worktime_alert_reads;
create policy wt_alert_receipt_read on public.worktime_alert_reads for select to authenticated using (
  exists(select 1 from public.profiles p where p.id=admin_profile_id and p.auth_user_id=(select auth.uid()) and p.active and p.role='admin')
);
drop policy if exists wt_device_read on public.worktime_device_authorizations;
create policy wt_device_read on public.worktime_device_authorizations for select to authenticated using (
  exists(select 1 from public.profiles p where p.auth_user_id=(select auth.uid()) and p.active and p.organization_id=organization_id and (p.role='admin' or p.id=profile_id))
);

create or replace function public.worktime_save_alert_preferences(p_preferences jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_profile public.profiles%rowtype; v_row public.worktime_alert_preferences%rowtype;
begin
 select * into v_profile from public.profiles where auth_user_id=auth.uid() and active and role='admin';
 if not found then raise exception 'ADMIN_REQUIRED'; end if;
 insert into public.worktime_alert_preferences(admin_profile_id,enabled,browser_enabled,absence_enabled,late_enabled,recurring_late_enabled,devices_enabled,missing_entry_enabled,recurring_late_threshold)
 values(v_profile.id,coalesce((p_preferences->>'enabled')::boolean,false),coalesce((p_preferences->>'browser_enabled')::boolean,false),
 coalesce((p_preferences->>'absence_enabled')::boolean,true),coalesce((p_preferences->>'late_enabled')::boolean,true),
 coalesce((p_preferences->>'recurring_late_enabled')::boolean,true),coalesce((p_preferences->>'devices_enabled')::boolean,true),
 coalesce((p_preferences->>'missing_entry_enabled')::boolean,true),greatest(2,least(10,coalesce((p_preferences->>'recurring_late_threshold')::integer,3))))
 on conflict(admin_profile_id) do update set enabled=excluded.enabled,browser_enabled=excluded.browser_enabled,
 absence_enabled=excluded.absence_enabled,late_enabled=excluded.late_enabled,recurring_late_enabled=excluded.recurring_late_enabled,
 devices_enabled=excluded.devices_enabled,missing_entry_enabled=excluded.missing_entry_enabled,
 recurring_late_threshold=excluded.recurring_late_threshold,updated_at=now() returning * into v_row;
 return to_jsonb(v_row);
end $$;

create or replace function public.worktime_register_device(p_device_id uuid,p_label text,p_user_agent text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_profile public.profiles%rowtype; v_row public.worktime_device_authorizations%rowtype; v_status text;
begin
 select * into v_profile from public.profiles where auth_user_id=auth.uid() and active;
 if not found then raise exception 'PROFILE_INACTIVE'; end if;
 if p_device_id is null or length(trim(coalesce(p_label,'')))<2 then raise exception 'DEVICE_INVALID'; end if;
 select * into v_row from public.worktime_device_authorizations where profile_id=v_profile.id and device_id=p_device_id for update;
 if found then
   update public.worktime_device_authorizations set last_seen_at=now() where id=v_row.id returning * into v_row;
 else
   v_status:=case when v_profile.role='admin' then 'approved' else 'pending' end;
   insert into public.worktime_device_authorizations(organization_id,profile_id,device_id,label,user_agent,status,last_seen_at)
   values(v_profile.organization_id,v_profile.id,p_device_id,left(trim(p_label),100),left(coalesce(p_user_agent,''),500),v_status,now()) returning * into v_row;
   insert into public.worktime_alerts(organization_id,event_key,kind,employee_id,title,body)
   values(v_profile.organization_id,'device:'||v_row.id::text,
     case when v_profile.role='admin' then 'device_new_admin' else 'device_pending' end,
     v_profile.id,'Novo dispositivo de '||v_profile.full_name,
     case when v_profile.role='admin' then 'Novo dispositivo utilizado por um administrador.' else 'Pede autorização para entrar: ' end ||v_row.label)
   on conflict(organization_id,event_key) do nothing;
 end if;
 return jsonb_build_object('id',v_row.id,'status',v_row.status,'label',v_row.label);
end $$;

create or replace function public.worktime_decide_device(p_authorization_id uuid,p_approve boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_admin public.profiles%rowtype; v_row public.worktime_device_authorizations%rowtype;
begin
 select * into v_admin from public.profiles where auth_user_id=auth.uid() and active and role='admin';
 if not found then raise exception 'ADMIN_REQUIRED'; end if;
 select * into v_row from public.worktime_device_authorizations where id=p_authorization_id and organization_id=v_admin.organization_id for update;
 if not found then raise exception 'DEVICE_NOT_FOUND'; end if;
 if v_row.profile_id=v_admin.id then raise exception 'SELF_DEVICE_CHANGE_FORBIDDEN'; end if;
 update public.worktime_device_authorizations set status=case when p_approve then 'approved' else 'rejected' end,
   decided_at=now(),decided_by=v_admin.id where id=v_row.id returning * into v_row;
 return jsonb_build_object('id',v_row.id,'status',v_row.status);
end $$;

create or replace function public.worktime_revoke_device(p_authorization_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_admin public.profiles%rowtype; v_row public.worktime_device_authorizations%rowtype;
begin
 select * into v_admin from public.profiles where auth_user_id=auth.uid() and active and role='admin';
 if not found then raise exception 'ADMIN_REQUIRED'; end if;
 select * into v_row from public.worktime_device_authorizations where id=p_authorization_id and organization_id=v_admin.organization_id for update;
 if not found then raise exception 'DEVICE_NOT_FOUND'; end if;
 if v_row.profile_id=v_admin.id then raise exception 'SELF_DEVICE_CHANGE_FORBIDDEN'; end if;
 update public.worktime_device_authorizations set status='revoked',decided_at=now(),decided_by=v_admin.id where id=v_row.id returning * into v_row;
 return jsonb_build_object('id',v_row.id,'status',v_row.status);
end $$;

create or replace function public.worktime_mark_alert_read(p_alert_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_admin public.profiles%rowtype;
begin
 select * into v_admin from public.profiles where auth_user_id=auth.uid() and active and role='admin';
 if not found then raise exception 'ADMIN_REQUIRED'; end if;
 if not exists(select 1 from public.worktime_alerts where id=p_alert_id and organization_id=v_admin.organization_id) then raise exception 'ALERT_NOT_FOUND'; end if;
 insert into public.worktime_alert_reads(alert_id,admin_profile_id) values(p_alert_id,v_admin.id) on conflict do nothing;
end $$;

-- A classificação de falta é sempre provisória até ser confirmada pela administração.
-- O varrimento compara o início real ao horário histórico e respeita a tolerância e estados manuais.
create or replace function public.worktime_scan_attendance_alerts()
returns integer language plpgsql security definer set search_path = '' as $$
declare
 v_admin public.profiles%rowtype; v_org uuid; v_count integer:=0; v_day date; v_employee record;
 v_segment record; v_version uuid; v_start timestamptz; v_end timestamptz; v_actual timestamptz;
 v_tol integer; v_late integer; v_total integer; v_threshold integer;
begin
 select * into v_admin from public.profiles where auth_user_id=auth.uid() and active and role='admin';
 if not found and coalesce(current_setting('request.jwt.claim.role',true),'') <> 'service_role' and
    coalesce(current_setting('request.jwt.claim.role',true),'') <> '' then
   raise exception 'ADMIN_REQUIRED';
 end if;
 for v_org in select id from public.organizations where active and (v_admin.id is null or id=v_admin.organization_id) loop
  select coalesce(min(recurring_late_threshold),3) into v_threshold
  from public.worktime_alert_preferences p join public.profiles admin on admin.id=p.admin_profile_id
  where admin.organization_id=v_org and admin.active and admin.role='admin' and p.enabled;
  v_threshold:=coalesce(v_threshold,3);
  for v_employee in select id,full_name,created_at from public.profiles
    where organization_id=v_org and role='employee' and active and (employee_code is null or employee_code not like 'REMOVIDO-%')
  loop
   for v_day in select generate_series((timezone('Europe/Lisbon',now())::date - 30)::timestamp,
      timezone('Europe/Lisbon',now())::date::timestamp,interval '1 day')::date loop
    if v_day < timezone('Europe/Lisbon',v_employee.created_at)::date then continue; end if;
    if exists(select 1 from public.day_statuses ds where ds.employee_id=v_employee.id and ds.date=v_day) then continue; end if;
    select sv.id into v_version from public.schedule_versions sv where sv.employee_id=v_employee.id
      and sv.effective_from<=v_day order by sv.effective_from desc,sv.revision desc limit 1;
    if v_version is null then continue; end if;
    select coalesce(tv.tolerance_minutes,0) into v_tol from public.tolerance_versions tv
      where tv.organization_id=v_org and tv.effective_from<=v_day
      order by tv.effective_from desc,tv.revision desc limit 1;
    v_tol:=coalesce(v_tol,0);
    for v_segment in select segment_no,start_time,end_time from public.schedule_days
      where schedule_version_id=v_version and enabled and weekday=extract(isodow from v_day)::integer
      order by segment_no loop
      v_start:=((v_day + v_segment.start_time) at time zone 'Europe/Lisbon');
      v_end:=((v_day + v_segment.end_time + case when v_segment.end_time<=v_segment.start_time then interval '1 day' else interval '0 day' end) at time zone 'Europe/Lisbon');
      select min(p.occurred_at) into v_actual from public.punches p
      where p.employee_id=v_employee.id and p.journey_date=v_day and p.type='clock_in' and p.deleted_at is null
        and (coalesce(p.schedule_segment_no,p.shift_no,1)=v_segment.segment_no);
      if v_actual is not null then
       v_late:=floor(extract(epoch from(v_actual-v_start))/60)::integer;
       if v_late>v_tol then
        insert into public.worktime_alerts(organization_id,event_key,kind,employee_id,title,body,work_date)
        values(v_org,'late:'||v_employee.id||':'||v_day||':'||v_segment.segment_no,'late',v_employee.id,
        'Entrada com atraso · '||v_employee.full_name, 'Atraso de '||v_late||' min no dia '||v_day||'.',v_day)
        on conflict(organization_id,event_key) do nothing;
        get diagnostics v_count=row_count;
        select count(*) into v_total from public.worktime_alerts a
          where a.organization_id=v_org and a.employee_id=v_employee.id and a.kind='late'
            and a.work_date between v_day-29 and v_day;
        if v_total>=v_threshold then
         insert into public.worktime_alerts(organization_id,event_key,kind,employee_id,title,body,work_date)
         values(v_org,'repeat:'||v_employee.id||':'||v_day,'recurring_late',v_employee.id,
         'Atrasos repetidos · '||v_employee.full_name,
         v_total||' entradas tardias nos últimos 30 dias (limite '||v_threshold||').',v_day)
         on conflict(organization_id,event_key) do nothing;
        end if;
       end if;
      elsif v_day >= timezone('Europe/Lisbon',now())::date-1 and now()>v_end+interval '60 minutes' then
        -- Não atribuir falta automaticamente; inclui ausência de picagem no final do turno.
        insert into public.worktime_alerts(organization_id,event_key,kind,employee_id,title,body,work_date)
        values(v_org,'possible_absence:'||v_employee.id||':'||v_day||':'||v_segment.segment_no,'possible_absence',v_employee.id,
        'Possível falta · '||v_employee.full_name,'Sem entrada registada no turno de '||v_day||'. Confirmar antes de classificar.',v_day)
        on conflict(organization_id,event_key) do nothing;
      elsif v_day = timezone('Europe/Lisbon',now())::date and now()>v_start+interval '45 minutes' then
        insert into public.worktime_alerts(organization_id,event_key,kind,employee_id,title,body,work_date)
        values(v_org,'missing:'||v_employee.id||':'||v_day||':'||v_segment.segment_no,'missing_entry',v_employee.id,
        'Entrada por registar · '||v_employee.full_name,'Início previsto '||to_char(v_start at time zone 'Europe/Lisbon','HH24:MI')||'. Ainda sem picagem.',v_day)
        on conflict(organization_id,event_key) do nothing;
      end if;
    end loop;
    v_version:=null;
   end loop;
  end loop;
 end loop;
 return v_count;
end $$;

-- As funções SECURITY DEFINER ficam sem EXECUTE implícito para PUBLIC/anon.
revoke all on function public.worktime_save_alert_preferences(jsonb) from public,anon;
revoke all on function public.worktime_register_device(uuid,text,text) from public,anon;
revoke all on function public.worktime_decide_device(uuid,boolean) from public,anon;
revoke all on function public.worktime_revoke_device(uuid) from public,anon;
revoke all on function public.worktime_mark_alert_read(uuid) from public,anon;
revoke all on function public.worktime_scan_attendance_alerts() from public,anon;
grant execute on function public.worktime_save_alert_preferences(jsonb) to authenticated;
grant execute on function public.worktime_register_device(uuid,text,text) to authenticated;
grant execute on function public.worktime_decide_device(uuid,boolean) to authenticated;
grant execute on function public.worktime_revoke_device(uuid) to authenticated;
grant execute on function public.worktime_mark_alert_read(uuid) to authenticated;
grant execute on function public.worktime_scan_attendance_alerts() to authenticated,service_role;
