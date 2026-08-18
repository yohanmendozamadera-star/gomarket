alter table public.profiles add column if not exists username text;
alter table public.profiles add column if not exists must_change_password boolean not null default false;

create unique index if not exists profiles_username_unique
on public.profiles (lower(username)) where username is not null;

create or replace function public.resolve_employee_username(login_username text)
returns text language sql stable security definer set search_path=public as $$
  select p.email from public.profiles p
  join public.organization_members m on m.user_id=p.id and m.status='active'
  where lower(p.username)=lower(trim(login_username)) limit 1
$$;

create or replace function public.create_company_employee(
  target_org uuid, employee_name text, employee_phone text, employee_email text,
  employee_username text, temporary_password text, employee_role text default 'employee'
) returns jsonb language plpgsql security definer set search_path=public,auth,extensions as $$
declare
  new_user_id uuid:=gen_random_uuid();
  new_member_id uuid;
  selected_role_id uuid;
  clean_email text:=lower(trim(employee_email));
  clean_username text:=lower(trim(employee_username));
begin
  if not public.is_org_owner(target_org) then raise exception 'Solo el propietario puede crear empleados'; end if;
  if nullif(trim(employee_name),'') is null or nullif(clean_email,'') is null or nullif(clean_username,'') is null then raise exception 'Completa los campos obligatorios'; end if;
  if clean_username !~ '^[a-z0-9._-]{3,40}$' then raise exception 'El usuario debe tener entre 3 y 40 caracteres válidos'; end if;
  if length(temporary_password)<8 then raise exception 'La clave temporal debe tener al menos 8 caracteres'; end if;
  if exists(select 1 from public.profiles where lower(email)=clean_email) or exists(select 1 from auth.users where lower(email)=clean_email) then raise exception 'Ese correo ya está registrado'; end if;
  if exists(select 1 from public.profiles where lower(username)=clean_username) then raise exception 'Ese usuario ya está registrado'; end if;
  if employee_role not in ('employee','organization_admin','order_operator','inventory_manager','catalog_manager','analyst','courier') then raise exception 'Rol no válido'; end if;

  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at,confirmation_token,email_change,email_change_token_new,recovery_token)
  values('00000000-0000-0000-0000-000000000000',new_user_id,'authenticated','authenticated',clean_email,crypt(temporary_password,gen_salt('bf')),now(),'{"provider":"email","providers":["email"]}'::jsonb,jsonb_build_object('full_name',trim(employee_name),'phone',trim(employee_phone),'username',clean_username),now(),now(),'','','','');

  insert into auth.identities(id,user_id,provider_id,identity_data,provider,last_sign_in_at,created_at,updated_at)
  values(gen_random_uuid(),new_user_id,clean_email,jsonb_build_object('sub',new_user_id::text,'email',clean_email,'email_verified',true),'email',now(),now(),now());

  insert into public.profiles(id,email,full_name,phone,platform_role,username,must_change_password)
  values(new_user_id,clean_email,trim(employee_name),trim(employee_phone),'customer',clean_username,true)
  on conflict(id) do update set email=excluded.email,full_name=excluded.full_name,phone=excluded.phone,username=excluded.username,must_change_password=true;

  insert into public.organization_members(organization_id,user_id,membership_type,status,joined_at)
  values(target_org,new_user_id,case when employee_role='organization_admin' then 'admin' else 'employee' end,'active',now()) returning id into new_member_id;

  if employee_role<>'employee' then
    select id into selected_role_id from public.roles where organization_id is null and code=employee_role limit 1;
    if selected_role_id is not null then insert into public.member_roles(member_id,role_id) values(new_member_id,selected_role_id) on conflict do nothing; end if;
  end if;
  return jsonb_build_object('user_id',new_user_id,'member_id',new_member_id,'username',clean_username);
end $$;

create or replace function public.get_company_employees(target_org uuid)
returns table(member_id uuid,user_id uuid,full_name text,phone text,email text,username text,membership_type text,role_code text,role_name text,status text,must_change_password boolean,created_at timestamptz)
language plpgsql stable security definer set search_path=public as $$
begin
  if not public.is_org_owner(target_org) then raise exception 'Solo el propietario puede consultar empleados'; end if;
  return query
  select m.id,m.user_id,coalesce(p.full_name,''),coalesce(p.phone,''),p.email,coalesce(p.username,''),m.membership_type::text,
    coalesce(r.code,'employee'),coalesce(r.name,'Empleado general'),m.status::text,p.must_change_password,m.created_at
  from public.organization_members m join public.profiles p on p.id=m.user_id
  left join public.member_roles mr on mr.member_id=m.id left join public.roles r on r.id=mr.role_id
  where m.organization_id=target_org and m.membership_type<>'owner'
  order by m.created_at desc;
end $$;

create or replace function public.update_company_employee_role(target_member uuid,new_role_code text)
returns void language plpgsql security definer set search_path=public as $$
declare target_org uuid;
begin
  select organization_id into target_org from public.organization_members where id=target_member and membership_type<>'owner';
  if target_org is null or not public.is_org_owner(target_org) then raise exception 'No autorizado'; end if;
  if new_role_code not in ('employee','organization_admin','order_operator','inventory_manager','catalog_manager','analyst','courier') then raise exception 'Rol no válido'; end if;
  delete from public.member_roles mr using public.roles r where mr.member_id=target_member and r.id=mr.role_id and r.organization_id is null and r.scope='organization';
  if new_role_code<>'employee' then insert into public.member_roles(member_id,role_id) select target_member,id from public.roles where organization_id is null and code=new_role_code limit 1; end if;
  update public.organization_members set membership_type=case when new_role_code='organization_admin' then 'admin' else 'employee' end where id=target_member;
end $$;

create or replace function public.set_company_employee_status(target_member uuid,new_status text)
returns void language plpgsql security definer set search_path=public as $$
declare target_org uuid;
begin
  if new_status not in ('active','suspended') then raise exception 'Estado no válido'; end if;
  select organization_id into target_org from public.organization_members where id=target_member and membership_type<>'owner';
  if target_org is null or not public.is_org_owner(target_org) then raise exception 'No autorizado'; end if;
  update public.organization_members set status=new_status where id=target_member;
end $$;

create or replace function public.complete_first_password_change()
returns void language plpgsql security definer set search_path=public as $$
begin update public.profiles set must_change_password=false where id=auth.uid(); end $$;

revoke all on function public.create_company_employee(uuid,text,text,text,text,text,text) from public;
revoke all on function public.get_company_employees(uuid) from public;
revoke all on function public.update_company_employee_role(uuid,text) from public;
revoke all on function public.set_company_employee_status(uuid,text) from public;
grant execute on function public.resolve_employee_username(text) to anon,authenticated;
grant execute on function public.create_company_employee(uuid,text,text,text,text,text,text) to authenticated;
grant execute on function public.get_company_employees(uuid) to authenticated;
grant execute on function public.update_company_employee_role(uuid,text) to authenticated;
grant execute on function public.set_company_employee_status(uuid,text) to authenticated;
grant execute on function public.complete_first_password_change() to authenticated;
