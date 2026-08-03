-- GoMarket core identity, organizations, roles and security.
-- Safe to run once on a new Supabase project.

create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  full_name text,
  avatar_url text,
  phone text,
  platform_role text not null default 'customer' check (platform_role in ('customer','platform_admin','super_admin')),
  status text not null default 'active' check (status in ('active','suspended','deleted')),
  last_seen_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text not null unique,
  legal_name text,
  tax_id text,
  logo_url text,
  status text not null default 'pending' check (status in ('pending','active','suspended','rejected')),
  owner_user_id uuid not null references public.profiles(id),
  approved_by uuid references public.profiles(id),
  approved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.branches (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null,
  code text not null,
  address text,
  city text,
  phone text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (organization_id, code)
);

create table if not exists public.organization_members (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  membership_type text not null default 'employee' check (membership_type in ('owner','admin','employee','courier')),
  status text not null default 'active' check (status in ('invited','active','suspended','removed')),
  joined_at timestamptz,
  created_at timestamptz not null default now(),
  unique (organization_id, user_id)
);

create table if not exists public.roles (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid references public.organizations(id) on delete cascade,
  name text not null,
  code text not null,
  description text,
  scope text not null check (scope in ('platform','organization')),
  is_system boolean not null default false,
  created_at timestamptz not null default now(),
  unique nulls not distinct (organization_id, code)
);

create table if not exists public.permissions (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  module text not null,
  action text not null,
  description text
);

create table if not exists public.role_permissions (
  role_id uuid not null references public.roles(id) on delete cascade,
  permission_id uuid not null references public.permissions(id) on delete cascade,
  primary key (role_id, permission_id)
);

create table if not exists public.member_roles (
  member_id uuid not null references public.organization_members(id) on delete cascade,
  role_id uuid not null references public.roles(id) on delete cascade,
  assigned_by uuid references public.profiles(id),
  assigned_at timestamptz not null default now(),
  primary key (member_id, role_id)
);

create table if not exists public.member_branches (
  member_id uuid not null references public.organization_members(id) on delete cascade,
  branch_id uuid not null references public.branches(id) on delete cascade,
  assigned_by uuid references public.profiles(id),
  assigned_at timestamptz not null default now(),
  primary key (member_id, branch_id)
);

create table if not exists public.invitations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  email text not null,
  role_id uuid references public.roles(id),
  token_hash text not null unique,
  status text not null default 'pending' check (status in ('pending','accepted','expired','revoked')),
  invited_by uuid not null references public.profiles(id),
  expires_at timestamptz not null,
  accepted_by uuid references public.profiles(id),
  accepted_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.audit_logs (
  id bigint generated always as identity primary key,
  actor_user_id uuid references public.profiles(id),
  organization_id uuid references public.organizations(id) on delete set null,
  branch_id uuid references public.branches(id) on delete set null,
  action text not null,
  entity_type text not null,
  entity_id text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists organization_members_user_idx on public.organization_members(user_id, status);
create index if not exists branches_org_idx on public.branches(organization_id);
create index if not exists roles_org_idx on public.roles(organization_id);
create index if not exists audit_logs_org_created_idx on public.audit_logs(organization_id, created_at desc);
create index if not exists invitations_org_email_idx on public.invitations(organization_id, lower(email));

create or replace function public.touch_updated_at()
returns trigger language plpgsql set search_path = '' as $$
begin new.updated_at = now(); return new; end; $$;

drop trigger if exists profiles_touch_updated_at on public.profiles;
create trigger profiles_touch_updated_at before update on public.profiles for each row execute function public.touch_updated_at();
drop trigger if exists organizations_touch_updated_at on public.organizations;
create trigger organizations_touch_updated_at before update on public.organizations for each row execute function public.touch_updated_at();

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id,email,full_name,avatar_url)
  values (new.id,new.email,coalesce(new.raw_user_meta_data->>'full_name',new.raw_user_meta_data->>'name'),new.raw_user_meta_data->>'avatar_url')
  on conflict (id) do update set email=excluded.email, full_name=coalesce(public.profiles.full_name,excluded.full_name), avatar_url=coalesce(public.profiles.avatar_url,excluded.avatar_url);
  return new;
end; $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert or update of email, raw_user_meta_data on auth.users for each row execute function public.handle_new_user();

insert into public.profiles (id,email,full_name,avatar_url)
select id,email,coalesce(raw_user_meta_data->>'full_name',raw_user_meta_data->>'name'),raw_user_meta_data->>'avatar_url' from auth.users
on conflict (id) do nothing;

create or replace function public.is_super_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists(select 1 from public.profiles p where p.id=auth.uid() and p.platform_role='super_admin' and p.status='active');
$$;

create or replace function public.is_platform_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists(select 1 from public.profiles p where p.id=auth.uid() and p.platform_role in ('super_admin','platform_admin') and p.status='active');
$$;

create or replace function public.is_org_member(target_org uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select public.is_platform_admin() or exists(select 1 from public.organization_members m where m.organization_id=target_org and m.user_id=auth.uid() and m.status='active');
$$;

create or replace function public.is_org_manager(target_org uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select public.is_platform_admin() or exists(select 1 from public.organization_members m where m.organization_id=target_org and m.user_id=auth.uid() and m.status='active' and m.membership_type in ('owner','admin'));
$$;

create or replace function public.can_access_branch(target_branch uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select public.is_platform_admin() or exists(
    select 1 from public.branches b join public.organization_members m on m.organization_id=b.organization_id
    left join public.member_branches mb on mb.member_id=m.id and mb.branch_id=b.id
    where b.id=target_branch and m.user_id=auth.uid() and m.status='active'
      and (m.membership_type in ('owner','admin') or mb.branch_id is not null)
  );
$$;

create or replace function public.has_permission(target_org uuid, permission_code text)
returns boolean language sql stable security definer set search_path = '' as $$
  select public.is_platform_admin() or exists(
    select 1 from public.organization_members m
    join public.member_roles mr on mr.member_id=m.id
    join public.role_permissions rp on rp.role_id=mr.role_id
    join public.permissions p on p.id=rp.permission_id
    where m.organization_id=target_org and m.user_id=auth.uid() and m.status='active' and p.code=permission_code
  );
$$;

revoke all on function public.is_super_admin() from public;
revoke all on function public.is_platform_admin() from public;
revoke all on function public.is_org_member(uuid) from public;
revoke all on function public.is_org_manager(uuid) from public;
revoke all on function public.can_access_branch(uuid) from public;
revoke all on function public.has_permission(uuid,text) from public;
grant execute on function public.is_super_admin() to authenticated;
grant execute on function public.is_platform_admin() to authenticated;
grant execute on function public.is_org_member(uuid) to authenticated;
grant execute on function public.is_org_manager(uuid) to authenticated;
grant execute on function public.can_access_branch(uuid) to authenticated;
grant execute on function public.has_permission(uuid,text) to authenticated;

insert into public.permissions(code,module,action,description) values
('organization.view','organization','view','Ver la empresa'),('organization.update','organization','update','Editar la empresa'),
('branches.manage','branches','manage','Administrar sedes'),('team.view','team','view','Ver el equipo'),('team.manage','team','manage','Administrar equipo'),
('roles.manage','roles','manage','Administrar roles y permisos'),('products.view','products','view','Ver productos'),
('products.create','products','create','Crear productos'),('products.update','products','update','Editar productos'),
('products.change_price','products','change_price','Cambiar precios'),('inventory.view','inventory','view','Ver inventario'),
('inventory.adjust','inventory','adjust','Registrar ajustes de inventario'),('orders.view','orders','view','Ver pedidos'),
('orders.accept','orders','accept','Aceptar pedidos'),('orders.update_status','orders','update_status','Cambiar estados'),
('orders.cancel','orders','cancel','Cancelar pedidos'),('customers.view','customers','view','Ver clientes propios'),
('promotions.manage','promotions','manage','Administrar promociones'),('reports.view','reports','view','Ver reportes'),
('reports.export','reports','export','Exportar reportes'),('finance.view','finance','view','Ver información financiera')
on conflict (code) do nothing;

insert into public.roles(organization_id,name,code,description,scope,is_system) values
(null,'Administrador de plataforma','platform_admin','Operación general de GoMarket','platform',true),
(null,'Propietario','owner','Control total de su empresa','organization',true),
(null,'Administrador de empresa','organization_admin','Administración operativa de la empresa','organization',true),
(null,'Operador de pedidos','order_operator','Gestión de pedidos','organization',true),
(null,'Encargado de inventario','inventory_manager','Productos e inventario','organization',true),
(null,'Gestor de catálogo','catalog_manager','Catálogo y precios','organization',true),
(null,'Analista','analyst','Reportes sin edición','organization',true),
(null,'Domiciliario','courier','Pedidos asignados y entrega','organization',true)
on conflict (organization_id,code) do nothing;

insert into public.role_permissions(role_id,permission_id)
select r.id,p.id from public.roles r cross join public.permissions p
where r.code='owner' and r.organization_id is null on conflict do nothing;
insert into public.role_permissions(role_id,permission_id)
select r.id,p.id from public.roles r join public.permissions p on p.code in ('organization.view','organization.update','branches.manage','team.view','team.manage','products.view','products.create','products.update','products.change_price','inventory.view','inventory.adjust','orders.view','orders.accept','orders.update_status','orders.cancel','customers.view','promotions.manage','reports.view','reports.export','finance.view')
where r.code='organization_admin' and r.organization_id is null on conflict do nothing;
insert into public.role_permissions(role_id,permission_id)
select r.id,p.id from public.roles r join public.permissions p on p.code in ('orders.view','orders.accept','orders.update_status') where r.code='order_operator' and r.organization_id is null on conflict do nothing;
insert into public.role_permissions(role_id,permission_id)
select r.id,p.id from public.roles r join public.permissions p on p.code in ('products.view','products.update','inventory.view','inventory.adjust') where r.code='inventory_manager' and r.organization_id is null on conflict do nothing;
insert into public.role_permissions(role_id,permission_id)
select r.id,p.id from public.roles r join public.permissions p on p.code in ('products.view','products.create','products.update','products.change_price') where r.code='catalog_manager' and r.organization_id is null on conflict do nothing;
insert into public.role_permissions(role_id,permission_id)
select r.id,p.id from public.roles r join public.permissions p on p.code in ('reports.view','reports.export','finance.view') where r.code='analyst' and r.organization_id is null on conflict do nothing;
insert into public.role_permissions(role_id,permission_id)
select r.id,p.id from public.roles r join public.permissions p on p.code in ('orders.view','orders.update_status') where r.code='courier' and r.organization_id is null on conflict do nothing;

alter table public.profiles enable row level security;
alter table public.organizations enable row level security;
alter table public.branches enable row level security;
alter table public.organization_members enable row level security;
alter table public.roles enable row level security;
alter table public.permissions enable row level security;
alter table public.role_permissions enable row level security;
alter table public.member_roles enable row level security;
alter table public.member_branches enable row level security;
alter table public.invitations enable row level security;
alter table public.audit_logs enable row level security;

create policy "profiles_read_self_or_admin" on public.profiles for select to authenticated using (id=auth.uid() or public.is_platform_admin());
create policy "profiles_update_self_or_super" on public.profiles for update to authenticated using (id=auth.uid() or public.is_super_admin()) with check (id=auth.uid() or public.is_super_admin());
create policy "organizations_read_member" on public.organizations for select to authenticated using (public.is_org_member(id));
create policy "organizations_create_authenticated" on public.organizations for insert to authenticated with check (owner_user_id=auth.uid());
create policy "organizations_update_manager" on public.organizations for update to authenticated using (public.is_org_manager(id)) with check (public.is_org_manager(id));
create policy "branches_read_member" on public.branches for select to authenticated using (public.is_org_member(organization_id));
create policy "branches_manage_manager" on public.branches for all to authenticated using (public.is_org_manager(organization_id)) with check (public.is_org_manager(organization_id));
create policy "members_read_org" on public.organization_members for select to authenticated using (public.is_org_member(organization_id));
create policy "members_manage_org" on public.organization_members for all to authenticated using (public.is_org_manager(organization_id)) with check (public.is_org_manager(organization_id));
create policy "permissions_read_authenticated" on public.permissions for select to authenticated using (true);
create policy "permissions_manage_super" on public.permissions for all to authenticated using (public.is_super_admin()) with check (public.is_super_admin());
create policy "roles_read_member" on public.roles for select to authenticated using (organization_id is null or public.is_org_member(organization_id));
create policy "roles_manage_org" on public.roles for all to authenticated using (organization_id is not null and public.is_org_manager(organization_id)) with check (organization_id is not null and public.is_org_manager(organization_id));
create policy "role_permissions_read" on public.role_permissions for select to authenticated using (exists(select 1 from public.roles r where r.id=role_id and (r.organization_id is null or public.is_org_member(r.organization_id))));
create policy "role_permissions_manage" on public.role_permissions for all to authenticated using (exists(select 1 from public.roles r where r.id=role_id and r.organization_id is not null and public.is_org_manager(r.organization_id))) with check (exists(select 1 from public.roles r where r.id=role_id and r.organization_id is not null and public.is_org_manager(r.organization_id)));
create policy "member_roles_read" on public.member_roles for select to authenticated using (exists(select 1 from public.organization_members m where m.id=member_id and public.is_org_member(m.organization_id)));
create policy "member_roles_manage" on public.member_roles for all to authenticated using (exists(select 1 from public.organization_members m where m.id=member_id and public.is_org_manager(m.organization_id))) with check (exists(select 1 from public.organization_members m where m.id=member_id and public.is_org_manager(m.organization_id)));
create policy "member_branches_read" on public.member_branches for select to authenticated using (exists(select 1 from public.organization_members m where m.id=member_id and public.is_org_member(m.organization_id)));
create policy "member_branches_manage" on public.member_branches for all to authenticated using (exists(select 1 from public.organization_members m where m.id=member_id and public.is_org_manager(m.organization_id))) with check (exists(select 1 from public.organization_members m where m.id=member_id and public.is_org_manager(m.organization_id)));
create policy "invitations_read_manager" on public.invitations for select to authenticated using (public.is_org_manager(organization_id));
create policy "invitations_manage_manager" on public.invitations for all to authenticated using (public.is_org_manager(organization_id)) with check (public.is_org_manager(organization_id) and invited_by=auth.uid());
create policy "audit_read_scoped" on public.audit_logs for select to authenticated using (public.is_platform_admin() or (organization_id is not null and public.is_org_manager(organization_id)) or actor_user_id=auth.uid());
create policy "audit_insert_authenticated" on public.audit_logs for insert to authenticated with check (actor_user_id=auth.uid());

grant usage on schema public to authenticated;
grant select,insert,update on public.profiles to authenticated;
grant select,insert,update on public.organizations to authenticated;
grant select,insert,update,delete on public.branches,public.organization_members,public.roles,public.role_permissions,public.member_roles,public.member_branches,public.invitations to authenticated;
grant select on public.permissions to authenticated;
grant select,insert on public.audit_logs to authenticated;

-- Bootstrap the project owner as the first super administrator.
update public.profiles set platform_role='super_admin'
where lower(email)=lower('yohanmendozamadera@gmail.com');
