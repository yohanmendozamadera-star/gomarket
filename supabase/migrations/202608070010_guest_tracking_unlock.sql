alter table public.marketplace_orders
  add column if not exists tracking_token uuid default gen_random_uuid();

update public.marketplace_orders set tracking_token=gen_random_uuid() where tracking_token is null;
alter table public.marketplace_orders alter column tracking_token set not null;
create unique index if not exists marketplace_orders_tracking_token_idx on public.marketplace_orders(tracking_token);

create or replace function public.unlock_order_customer_data(target_order uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare ord marketplace_orders%rowtype; bal numeric;
begin
  select * into ord from marketplace_orders where id=target_order for update;
  if ord.id is null or not is_org_manager(ord.organization_id) then raise exception 'not_authorized'; end if;
  if ord.customer_data_unlocked then
    select balance into bal from wallet_accounts where organization_id=ord.organization_id;
    return jsonb_build_object('unlocked',true,'balance',bal,'charged',false);
  end if;
  select balance into bal from wallet_accounts where organization_id=ord.organization_id for update;
  if coalesce(bal,0)<ord.commission_amount then raise exception 'insufficient_coins'; end if;
  update wallet_accounts set balance=balance-ord.commission_amount,updated_at=now()
    where organization_id=ord.organization_id returning balance into bal;
  insert into wallet_transactions(organization_id,order_id,kind,amount,balance_after,description)
    values(ord.organization_id,ord.id,'commission',-ord.commission_amount,bal,'Comisión GoMarket 9,5% · datos desbloqueados');
  update marketplace_orders set customer_data_unlocked=true,updated_at=now() where id=target_order;
  return jsonb_build_object('unlocked',true,'balance',bal,'charged',true);
end $$;

create or replace function public.find_guest_order(target_order_number bigint,target_phone text)
returns table(order_number bigint,status text,payment_method text,total numeric,organization_name text,created_at timestamptz,updated_at timestamptz)
language sql stable security definer set search_path=public as $$
  select o.order_number,o.status,o.payment_method,o.total,g.name,o.created_at,o.updated_at
  from marketplace_orders o join organizations g on g.id=o.organization_id
  where o.order_number=target_order_number
    and regexp_replace(o.customer_phone,'[^0-9]','','g')=regexp_replace(target_phone,'[^0-9]','','g')
  limit 1;
$$;

create or replace function public.create_marketplace_order(payload jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare oid uuid; tracking uuid; order_no bigint; org uuid; st numeric; fee numeric; tot numeric; comm numeric; pm text; next_status text; item jsonb;
begin
 org=(payload->>'organization_id')::uuid;pm=payload->>'payment_method';st=(payload->>'subtotal')::numeric;fee=coalesce((payload->>'delivery_fee')::numeric,0);tot=st+fee;comm=round(st*.095,2);
 next_status=case when pm='cash_on_delivery' then 'pending_confirmation' else 'orders' end;
 insert into marketplace_orders(organization_id,customer_user_id,customer_name,customer_email,customer_phone,delivery_address,delivery_city,delivery_lat,delivery_lng,payment_method,payment_status,status,subtotal,delivery_fee,total,commission_amount,notes)
 values(org,auth.uid(),payload->>'customer_name',nullif(payload->>'customer_email',''),payload->>'customer_phone',payload->>'delivery_address',payload->>'delivery_city',(payload->>'delivery_lat')::double precision,(payload->>'delivery_lng')::double precision,pm,case when pm='card' then 'paid' else 'cash_on_delivery' end,next_status,st,fee,tot,comm,payload->>'notes') returning id,tracking_token,order_number into oid,tracking,order_no;
 for item in select * from jsonb_array_elements(payload->'items') loop insert into marketplace_order_items(order_id,product_name,quantity,unit_price,total) values(oid,item->>'name',(item->>'quantity')::int,(item->>'price')::numeric,(item->>'quantity')::int*(item->>'price')::numeric);end loop;
 insert into order_status_history(order_id,status,actor_user_id,note) values(oid,next_status,auth.uid(),'Pedido creado');
 return jsonb_build_object('id',oid,'order_number',order_no,'tracking_token',tracking,'status',next_status,'total',tot,'commission',comm);
end $$;

grant execute on function public.unlock_order_customer_data(uuid) to authenticated;
grant execute on function public.find_guest_order(bigint,text) to anon,authenticated;
grant execute on function public.create_marketplace_order(jsonb) to anon,authenticated;
notify pgrst,'reload schema';
