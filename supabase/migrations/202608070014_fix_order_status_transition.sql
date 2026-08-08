drop function if exists public.set_provider_order_status(uuid,text,text,double precision,double precision);

create function public.set_provider_order_status(
  target_order uuid,
  next_status text,
  status_note text default null,
  new_delivery_lat double precision default null,
  new_delivery_lng double precision default null
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare ord marketplace_orders%rowtype; allowed boolean:=false;
begin
  select * into ord from marketplace_orders where id=target_order for update;
  if ord.id is null or not is_org_manager(ord.organization_id) then raise exception 'not_authorized'; end if;
  allowed:=case
    when ord.status='pending_confirmation' then next_status in ('orders','cancelled')
    when ord.status in ('orders','confirmed') then next_status in ('preparing','cancelled')
    when ord.status='preparing' then next_status in ('dispatched','cancelled')
    when ord.status='dispatched' then next_status in ('out_for_delivery','returned','cancelled')
    when ord.status='out_for_delivery' then next_status in ('delivered','returned')
    else false end;
  if not allowed then raise exception 'invalid_transition_%_to_%',ord.status,next_status; end if;
  update marketplace_orders set status=next_status,updated_at=now(),
    return_reason=case when next_status in ('returned','cancelled') then status_note else return_reason end,
    delivered_lat=case when next_status='delivered' then new_delivery_lat else delivered_lat end,
    delivered_lng=case when next_status='delivered' then new_delivery_lng else delivered_lng end
  where id=target_order;
  insert into order_status_history(order_id,status,actor_user_id,note) values(target_order,next_status,auth.uid(),status_note);
  return jsonb_build_object('status',next_status,'updated',true);
end $$;

grant execute on function public.set_provider_order_status(uuid,text,text,double precision,double precision) to authenticated;
notify pgrst,'reload schema';
