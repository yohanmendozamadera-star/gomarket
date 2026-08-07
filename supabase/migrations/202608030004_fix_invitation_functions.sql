create or replace function public.get_provider_invitation(raw_token text)
returns table(organization_id uuid, organization_name text, invited_email text, invitation_status text, expires_at timestamptz)
language sql stable security definer set search_path=public as $$
  select o.id,o.name,i.email,i.status,i.expires_at
  from public.invitations i join public.organizations o on o.id=i.organization_id
  where i.token_hash=encode(extensions.digest(raw_token,'sha256'),'hex') limit 1;
$$;

create or replace function public.accept_provider_invitation(raw_token text)
returns uuid language plpgsql security definer set search_path=public as $$
declare inv public.invitations%rowtype; mid uuid;
begin
  if auth.uid() is null then raise exception 'authentication_required'; end if;
  select * into inv from public.invitations where token_hash=encode(extensions.digest(raw_token,'sha256'),'hex') for update;
  if inv.id is null then raise exception 'invitation_not_found'; end if;
  if inv.status<>'pending' or inv.expires_at<now() then raise exception 'invitation_expired'; end if;
  if lower(inv.email)<>lower(coalesce(auth.jwt()->>'email','')) then raise exception 'email_mismatch'; end if;
  insert into public.organization_members(organization_id,user_id,status,joined_at)
  values(inv.organization_id,auth.uid(),'active',now())
  on conflict(organization_id,user_id) do update set status='active'
  returning id into mid;
  if inv.role_id is not null then insert into public.member_roles(member_id,role_id) values(mid,inv.role_id) on conflict do nothing; end if;
  update public.invitations set status='accepted',accepted_by=auth.uid(),accepted_at=now() where id=inv.id;
  return inv.organization_id;
end;
$$;

revoke all on function public.get_provider_invitation(text) from public;
revoke all on function public.accept_provider_invitation(text) from public;
grant execute on function public.get_provider_invitation(text) to anon,authenticated;
grant execute on function public.accept_provider_invitation(text) to authenticated;
