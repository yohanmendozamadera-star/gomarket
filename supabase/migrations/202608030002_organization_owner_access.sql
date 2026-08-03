-- Ensure the creator of an organization can immediately access and manage it.
create or replace function public.is_org_owner(target_org uuid)
returns boolean language sql stable security definer set search_path=public as $$
  select exists(
    select 1 from public.organizations o
    where o.id=target_org and o.owner_user_id=auth.uid()
  ) or public.is_platform_admin();
$$;

revoke all on function public.is_org_owner(uuid) from public;
grant execute on function public.is_org_owner(uuid) to authenticated;

drop policy if exists "organizations_read_owner" on public.organizations;
create policy "organizations_read_owner" on public.organizations
for select to authenticated using (owner_user_id=auth.uid() or public.is_platform_admin());

drop policy if exists "organizations_update_owner" on public.organizations;
create policy "organizations_update_owner" on public.organizations
for update to authenticated using (public.is_org_owner(id)) with check (public.is_org_owner(id));

drop policy if exists "members_create_owner" on public.organization_members;
create policy "members_create_owner" on public.organization_members
for insert to authenticated with check (public.is_org_owner(organization_id));

create or replace function public.bootstrap_organization_owner()
returns trigger language plpgsql security definer set search_path=public as $$
declare
  new_member_id uuid;
  owner_role_id uuid;
begin
  insert into public.organization_members(organization_id,user_id,status,joined_at)
  values(new.id,new.owner_user_id,'active',now())
  on conflict (organization_id,user_id) do update set status='active',joined_at=coalesce(public.organization_members.joined_at,now())
  returning id into new_member_id;

  select id into owner_role_id from public.roles where organization_id is null and name='organization_owner' limit 1;
  if owner_role_id is not null then
    insert into public.member_roles(member_id,role_id) values(new_member_id,owner_role_id) on conflict do nothing;
  end if;
  return new;
end;
$$;

drop trigger if exists on_organization_created on public.organizations;
create trigger on_organization_created after insert on public.organizations
for each row execute function public.bootstrap_organization_owner();

-- Backfill membership for organizations created before this migration.
insert into public.organization_members(organization_id,user_id,status,joined_at)
select o.id,o.owner_user_id,'active',now() from public.organizations o
on conflict (organization_id,user_id) do nothing;
