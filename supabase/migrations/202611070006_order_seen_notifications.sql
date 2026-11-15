create table if not exists public.order_user_views (
  order_id uuid not null references public.marketplace_orders(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  seen_at timestamptz not null default now(),
  primary key(order_id, user_id)
);

alter table public.order_user_views enable row level security;
revoke all on public.order_user_views from anon, authenticated;

create or replace function public.get_unseen_store_order_count(target_org uuid default null)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare result integer;
begin
  if auth.uid() is null then raise exception 'authentication_required'; end if;
  if target_org is null then
    if not public.is_super_admin() then raise exception 'not_authorized'; end if;
    select count(*)::integer into result
    from public.marketplace_orders o
    where not coalesce(o.is_internal_sale,false)
      and not exists(select 1 from public.order_user_views v where v.order_id=o.id and v.user_id=auth.uid());
  else
    if not (public.is_org_member(target_org) or public.is_super_admin()) then raise exception 'not_authorized'; end if;
    select count(*)::integer into result
    from public.marketplace_orders o
    where o.organization_id=target_org and not coalesce(o.is_internal_sale,false)
      and not exists(select 1 from public.order_user_views v where v.order_id=o.id and v.user_id=auth.uid());
  end if;
  return result;
end $$;

create or replace function public.mark_store_orders_seen(target_org uuid default null)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare affected integer;
begin
  if auth.uid() is null then raise exception 'authentication_required'; end if;
  if target_org is null and not public.is_super_admin() then raise exception 'not_authorized'; end if;
  if target_org is not null and not (public.is_org_member(target_org) or public.is_super_admin()) then raise exception 'not_authorized'; end if;
  insert into public.order_user_views(order_id,user_id)
  select o.id,auth.uid() from public.marketplace_orders o
  where not coalesce(o.is_internal_sale,false) and (target_org is null or o.organization_id=target_org)
  on conflict(order_id,user_id) do update set seen_at=now();
  get diagnostics affected = row_count;
  return affected;
end $$;

revoke execute on function public.get_unseen_store_order_count(uuid) from public,anon;
revoke execute on function public.mark_store_orders_seen(uuid) from public,anon;
grant execute on function public.get_unseen_store_order_count(uuid) to authenticated;
grant execute on function public.mark_store_orders_seen(uuid) to authenticated;
notify pgrst,'reload schema';
