create or replace function public.set_provider_order_status(target_order uuid,next_status text,status_note text default null,new_delivery_lat double precision default null,new_delivery_lng double precision default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare ord marketplace_orders%rowtype; allowed boolean:=false;
begin
  select * into ord from marketplace_orders where id=target_order for update;
  if ord.id is null or not is_org_manager(ord.organization_id) then raise exception 'not_authorized'; end if;
  allowed:=case
    when ord.status in ('pending_confirmation','returned') then next_status in ('orders','cancelled')
    when ord.status in ('orders','confirmed') then next_status in ('preparing','cancelled')
    when ord.status='preparing' then next_status in ('dispatched','cancelled')
    when ord.status='dispatched' then next_status='out_for_delivery'
    when ord.status='out_for_delivery' then next_status='delivered'
    else false end;
  if not allowed then raise exception 'invalid_transition_%_to_%',ord.status,next_status; end if;
  update marketplace_orders set status=next_status,updated_at=now(),
    return_reason=case when next_status='cancelled' then status_note else return_reason end,
    delivered_lat=case when next_status='delivered' then new_delivery_lat else delivered_lat end,
    delivered_lng=case when next_status='delivered' then new_delivery_lng else delivered_lng end
  where id=target_order;
  insert into order_status_history(order_id,status,actor_user_id,note)
  values(target_order,next_status,auth.uid(),case when ord.status='returned' and next_status='orders' then 'Pedido devuelto confirmado nuevamente' else status_note end);
  return jsonb_build_object('status',next_status,'updated',true);
end $$;

create or replace function public.update_order_delivery_details(target_order uuid,new_address text,new_city text,new_notes text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare ord marketplace_orders%rowtype;
begin
  select * into ord from marketplace_orders where id=target_order for update;
  if ord.id is null or not is_org_manager(ord.organization_id) then raise exception 'not_authorized'; end if;
  if ord.status in ('delivered','cancelled') then raise exception 'order_closed'; end if;
  if nullif(trim(new_address),'') is null then raise exception 'address_required'; end if;
  update marketplace_orders set delivery_address=trim(new_address),delivery_city=coalesce(nullif(trim(new_city),''),delivery_city),notes=coalesce(nullif(trim(new_notes),''),notes),updated_at=now() where id=target_order;
  insert into order_status_history(order_id,status,actor_user_id,note) values(target_order,ord.status,auth.uid(),'Datos de entrega actualizados por el proveedor');
  return jsonb_build_object('updated',true);
end $$;

grant execute on function public.set_provider_order_status(uuid,text,text,double precision,double precision) to authenticated;
grant execute on function public.update_order_delivery_details(uuid,text,text,text) to authenticated;
notify pgrst,'reload schema';
