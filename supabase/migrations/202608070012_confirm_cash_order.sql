create or replace function public.confirm_cash_order(target_order uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare ord marketplace_orders%rowtype;
begin
  select * into ord from marketplace_orders where id=target_order for update;
  if ord.id is null or not is_org_manager(ord.organization_id) then raise exception 'not_authorized'; end if;
  if ord.payment_method<>'cash_on_delivery' or ord.status<>'pending_confirmation' then raise exception 'invalid_confirmation'; end if;
  update marketplace_orders set status='orders',updated_at=now() where id=target_order;
  insert into order_status_history(order_id,status,actor_user_id,note)
    values(target_order,'orders',auth.uid(),'Pedido contra entrega confirmado por el proveedor');
  return jsonb_build_object('status','orders','confirmed',true);
end $$;

grant execute on function public.confirm_cash_order(uuid) to authenticated;
notify pgrst,'reload schema';
