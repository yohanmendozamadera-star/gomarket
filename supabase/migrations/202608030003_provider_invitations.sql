-- Secure provider invitation lookup and acceptance.
create or replace function public.invitation_token_hash(raw_token text)
returns text language sql immutable as $$
  select encode(digest(raw_token, 'sha256'), 'hex');
$$;

create or replace function public.get_provider_invitation(raw_token text)
returns table(invitation_id uuid, organization_id uuid, organization_name text, invited_email text, invitation_status text, expires_at timestamptz)
language sql stable security definer set search_path=public as $$
  select i.id,o.id,o.name,i.email,i.status,i.expires_at
  from public.invitations i
  join public.organizations o on o.id=i.organization_id
  where i.token_hash=public.invitation_token_hash(raw_token)
  limit 1;
$$;

create or replace function public.accept_provider_invitation(raw_token text)
returns uuid language plpgsql security definer set search_path=public as $$
declare
  invite public.invitations%rowtype;
  new_member_id uuid;
begin
  if auth.uid() is null then raise exception 'authentication_required'; end if;
  select * into invite from public.invitations
  where token_hash=public.invitation_token_hash(raw_token) for update;
  if invite.id is null then raise exception 'invitation_not_found'; end if;
  if invite.status <> 'pending' or invite.expires_at < now() then raise exception 'invitation_expired'; end if;
  if lower(invite.email) <> lower(coalesce(auth.jwt()->>'email','')) then raise exception 'email_mismatch'; end if;

  insert into public.organization_members(organization_id,user_id,status,joined_at)
  values(invite.organization_id,auth.uid(),'active',now())
  on conflict (organization_id,user_id) do update set status='active',joined_at=coalesce(public.organization_members.joined_at,now())
  returning id into new_member_id;

  if invite.role_id is not null then
    insert into public.member_roles(member_id,role_id) values(new_member_id,invite.role_id) on conflict do nothing;
  end if;
  update public.invitations set status='accepted',accepted_by=auth.uid(),accepted_at=now() where id=invite.id;
  return invite.organization_id;
end;
$$;

revoke all on function public.get_provider_invitation(text) from public;
revoke all on function public.accept_provider_invitation(text) from public;
grant execute on function public.get_provider_invitation(text) to anon,authenticated;
grant execute on function public.accept_provider_invitation(text) to authenticated;

-- Correct and backfill the owner role for every organization creator.
insert into public.member_roles(member_id,role_id)
select m.id,r.id
from public.organization_members m
join public.organizations o on o.id=m.organization_id and o.owner_user_id=m.user_id
join public.roles r on r.code='owner' and r.organization_id is null
on conflict do nothing;

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
  select id into owner_role_id from public.roles where organization_id is null and code='owner' limit 1;
  if owner_role_id is not null then
    insert into public.member_roles(member_id,role_id) values(new_member_id,owner_role_id) on conflict do nothing;
  end if;
  return new;
end;
$$;
