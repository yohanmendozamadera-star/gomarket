create or replace function public.review_provider_application(target_application uuid, decision text)
returns uuid language plpgsql security definer set search_path=public as $$
declare
  application public.provider_applications;
  org_id uuid;
  org_slug text;
begin
  if not public.is_platform_admin() then raise exception 'not_authorized'; end if;
  if decision not in ('approved','rejected') then raise exception 'invalid_decision'; end if;

  select * into application from public.provider_applications
  where id=target_application for update;
  if not found then raise exception 'application_not_found'; end if;
  if application.status<>'pending' then return application.organization_id; end if;

  if decision='rejected' then
    update public.provider_applications set status='rejected' where id=target_application;
    return null;
  end if;

  select id into org_id from public.organizations where owner_user_id=application.user_id order by created_at limit 1;
  if org_id is null then
    org_slug=regexp_replace(lower(application.business_name),'[^a-z0-9]+','-','g');
    org_slug=trim(both '-' from org_slug)||'-'||left(replace(gen_random_uuid()::text,'-',''),8);
    insert into public.organizations(name,slug,legal_name,tax_id,status,owner_user_id,approved_by,approved_at)
    values(application.business_name,org_slug,application.business_name,application.tax_id,'active',application.user_id,auth.uid(),now())
    returning id into org_id;
  else
    update public.organizations set status='active',approved_by=auth.uid(),approved_at=now() where id=org_id;
  end if;

  insert into public.organization_members(organization_id,user_id,membership_type,status,joined_at)
  values(org_id,application.user_id,'owner','active',now())
  on conflict(organization_id,user_id) do update set membership_type='owner',status='active',joined_at=coalesce(public.organization_members.joined_at,now());
  insert into public.wallet_accounts(organization_id,balance) values(org_id,0) on conflict do nothing;
  update public.provider_applications set status='approved',organization_id=org_id where id=target_application;
  return org_id;
end $$;

grant execute on function public.review_provider_application(uuid,text) to authenticated;
notify pgrst,'reload schema';
