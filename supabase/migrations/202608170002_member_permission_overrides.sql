create table if not exists public.member_permission_overrides (
  member_id uuid not null references public.organization_members(id) on delete cascade,
  permission_id uuid not null references public.permissions(id) on delete cascade,
  enabled boolean not null,
  updated_by uuid references public.profiles(id),
  updated_at timestamptz not null default now(),
  primary key(member_id,permission_id)
);

alter table public.member_permission_overrides enable row level security;

create or replace function public.has_permission(target_org uuid, permission_code text)
returns boolean language sql stable security definer set search_path='' as $$
  select public.is_platform_admin() or coalesce((
    select coalesce(o.enabled,exists(
      select 1 from public.member_roles mr
      join public.role_permissions rp on rp.role_id=mr.role_id
      where mr.member_id=m.id and rp.permission_id=p.id
    ))
    from public.organization_members m cross join public.permissions p
    left join public.member_permission_overrides o on o.member_id=m.id and o.permission_id=p.id
    where m.organization_id=target_org and m.user_id=auth.uid() and m.status='active' and p.code=permission_code
    limit 1
  ),false)
$$;

create or replace function public.get_my_permissions(target_org uuid)
returns text[] language sql stable security definer set search_path='' as $$
  select coalesce(array_agg(p.code order by p.code),array[]::text[])
  from public.permissions p where public.has_permission(target_org,p.code)
$$;

create or replace function public.get_member_permission_settings(target_member uuid)
returns table(permission_code text,permission_name text,module text,enabled boolean,role_default boolean,is_override boolean)
language plpgsql stable security definer set search_path='' as $$
declare member_org uuid;
begin
  select m.organization_id into member_org from public.organization_members m where m.id=target_member;
  if member_org is null or not (public.is_platform_admin() or public.is_org_owner(member_org)) then raise exception 'No autorizado'; end if;
  return query select p.code,coalesce(p.description,p.code),p.module,
    coalesce(o.enabled,exists(select 1 from public.member_roles mr join public.role_permissions rp on rp.role_id=mr.role_id where mr.member_id=target_member and rp.permission_id=p.id)),
    exists(select 1 from public.member_roles mr join public.role_permissions rp on rp.role_id=mr.role_id where mr.member_id=target_member and rp.permission_id=p.id),
    (o.member_id is not null)
  from public.permissions p left join public.member_permission_overrides o on o.member_id=target_member and o.permission_id=p.id
  order by p.module,p.code;
end $$;

create or replace function public.set_member_permission(target_member uuid,target_permission text,is_enabled boolean)
returns void language plpgsql security definer set search_path='' as $$
declare member_org uuid; selected_permission uuid;
begin
  select m.organization_id into member_org from public.organization_members m where m.id=target_member and m.membership_type<>'owner';
  if member_org is null or not (public.is_platform_admin() or public.is_org_owner(member_org)) then raise exception 'No autorizado'; end if;
  select p.id into selected_permission from public.permissions p where p.code=target_permission;
  if selected_permission is null then raise exception 'Permiso no válido'; end if;
  insert into public.member_permission_overrides(member_id,permission_id,enabled,updated_by,updated_at)
  values(target_member,selected_permission,is_enabled,auth.uid(),now())
  on conflict(member_id,permission_id) do update set enabled=excluded.enabled,updated_by=excluded.updated_by,updated_at=now();
end $$;

create or replace function public.get_company_employees(target_org uuid)
returns table(member_id uuid,user_id uuid,full_name text,phone text,email text,username text,membership_type text,role_code text,role_name text,status text,must_change_password boolean,created_at timestamptz)
language plpgsql stable security definer set search_path=public as $$
begin
  if not (public.is_platform_admin() or public.is_org_owner(target_org)) then raise exception 'No autorizado'; end if;
  return query select m.id,m.user_id,coalesce(p.full_name,''),coalesce(p.phone,''),p.email,coalesce(p.username,''),m.membership_type::text,
    coalesce(r.code,'employee'),coalesce(r.name,'Empleado general'),m.status::text,p.must_change_password,m.created_at
  from public.organization_members m join public.profiles p on p.id=m.user_id
  left join public.member_roles mr on mr.member_id=m.id left join public.roles r on r.id=mr.role_id
  where m.organization_id=target_org and m.membership_type<>'owner' order by m.created_at desc;
end $$;

create or replace function public.update_company_employee_role(target_member uuid,new_role_code text)
returns void language plpgsql security definer set search_path=public as $$
declare target_org uuid;
begin
  select organization_id into target_org from public.organization_members where id=target_member and membership_type<>'owner';
  if target_org is null or not (public.is_platform_admin() or public.is_org_owner(target_org)) then raise exception 'No autorizado'; end if;
  if new_role_code not in ('employee','organization_admin','order_operator','inventory_manager','catalog_manager','analyst','courier') then raise exception 'Rol no válido'; end if;
  delete from public.member_roles mr using public.roles r where mr.member_id=target_member and r.id=mr.role_id and r.organization_id is null and r.scope='organization';
  delete from public.member_permission_overrides where member_id=target_member;
  if new_role_code<>'employee' then insert into public.member_roles(member_id,role_id) select target_member,id from public.roles where organization_id is null and code=new_role_code limit 1; end if;
  update public.organization_members set membership_type=case when new_role_code='organization_admin' then 'admin' else 'employee' end where id=target_member;
end $$;

create or replace function public.set_company_employee_status(target_member uuid,new_status text)
returns void language plpgsql security definer set search_path=public as $$
declare target_org uuid;
begin
  if new_status not in ('active','suspended') then raise exception 'Estado no válido'; end if;
  select organization_id into target_org from public.organization_members where id=target_member and membership_type<>'owner';
  if target_org is null or not (public.is_platform_admin() or public.is_org_owner(target_org)) then raise exception 'No autorizado'; end if;
  update public.organization_members set status=new_status where id=target_member;
end $$;

revoke all on function public.get_my_permissions(uuid) from public;
revoke all on function public.get_member_permission_settings(uuid) from public;
revoke all on function public.set_member_permission(uuid,text,boolean) from public;
grant execute on function public.get_my_permissions(uuid) to authenticated;
grant execute on function public.get_member_permission_settings(uuid) to authenticated;
grant execute on function public.set_member_permission(uuid,text,boolean) to authenticated;
