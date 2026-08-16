alter table public.marketplace_orders
  add column if not exists discount_percent numeric(6,2) not null default 0,
  add column if not exists discount_amount numeric(14,2) not null default 0;

alter table public.marketplace_orders drop constraint if exists marketplace_orders_payment_method_check;
alter table public.marketplace_orders add constraint marketplace_orders_payment_method_check
  check(payment_method in ('card','cash_on_delivery','credit'));

create or replace function public.create_marketplace_order(payload jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare oid uuid; tracking uuid; order_no bigint; org uuid; st numeric; fee numeric; tot numeric; pm text; next_status text; item jsonb; discount_rate numeric; discount_value numeric;
begin
 org=(payload->>'organization_id')::uuid;
 pm=payload->>'payment_method';
 if pm not in ('card','cash_on_delivery','credit') then raise exception 'invalid_payment_method'; end if;
 if pm='credit' and not public.is_org_member(org) then raise exception 'credit_requires_provider_member'; end if;
 st=(payload->>'subtotal')::numeric;
 fee=greatest(0,coalesce((payload->>'delivery_fee')::numeric,0));
 discount_rate=least(100,greatest(0,coalesce((payload->>'discount_percent')::numeric,0)));
 discount_value=round(st*discount_rate/100,2);
 tot=greatest(0,st-discount_value+fee);
 next_status=case when pm='cash_on_delivery' then 'pending_confirmation' else 'orders' end;
 insert into marketplace_orders(organization_id,customer_user_id,customer_name,customer_email,customer_phone,delivery_address,delivery_city,delivery_lat,delivery_lng,payment_method,payment_status,status,subtotal,discount_percent,discount_amount,delivery_fee,total,commission_amount,customer_data_unlocked,notes)
 values(org,auth.uid(),payload->>'customer_name',nullif(payload->>'customer_email',''),payload->>'customer_phone',payload->>'delivery_address',payload->>'delivery_city',(payload->>'delivery_lat')::double precision,(payload->>'delivery_lng')::double precision,pm,case when pm='card' then 'paid' when pm='credit' then 'credit' else 'cash_on_delivery' end,next_status,st,discount_rate,discount_value,fee,tot,0,true,payload->>'notes')
 returning id,tracking_token,order_number into oid,tracking,order_no;
 for item in select * from jsonb_array_elements(payload->'items') loop
  insert into marketplace_order_items(order_id,product_name,quantity,unit_price,total,unit_measure,unit_quantity)
  values(oid,item->>'name',(item->>'quantity')::numeric,(item->>'price')::numeric,(item->>'quantity')::numeric*(item->>'price')::numeric,coalesce(nullif(item->>'unit_measure',''),'unidad'),coalesce((item->>'unit_quantity')::numeric,1));
 end loop;
 if pm='credit' then
  insert into credit_sales(organization_id,order_id,customer_name,total,paid_amount,status)
  values(org,oid,payload->>'customer_name',tot,0,'active');
 end if;
 insert into order_status_history(order_id,status,actor_user_id,note) values(oid,next_status,auth.uid(),'Pedido creado');
 return jsonb_build_object('id',oid,'order_number',order_no,'tracking_token',tracking,'status',next_status,'total',tot);
end $$;

create or replace function public.get_provider_orders(target_org uuid)
returns table(id uuid,order_number bigint,status text,payment_method text,payment_status text,total numeric,commission_amount numeric,customer_data_unlocked boolean,customer_name text,customer_phone text,delivery_address text,delivery_city text,created_at timestamptz,updated_at timestamptz,delivered_at timestamptz,cancelled_at timestamptz,commission_refund_due_at timestamptz,commission_refunded_at timestamptz)
language sql stable security definer set search_path=public as $$
 select o.id,o.order_number,o.status,o.payment_method,o.payment_status,o.total,0::numeric,true,
  o.customer_name,o.customer_phone,o.delivery_address,o.delivery_city,
  o.created_at,o.updated_at,o.delivered_at,o.cancelled_at,null::timestamptz,null::timestamptz
 from marketplace_orders o
 where o.organization_id=target_org and (public.is_org_member(target_org) or public.is_platform_admin())
 order by o.created_at desc
$$;

grant execute on function public.create_marketplace_order(jsonb) to anon,authenticated;
grant execute on function public.get_provider_orders(uuid) to authenticated;
notify pgrst,'reload schema';
