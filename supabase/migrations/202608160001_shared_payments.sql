alter table public.marketplace_orders
  add column if not exists shared_cash_amount numeric(14,2) not null default 0,
  add column if not exists shared_card_amount numeric(14,2) not null default 0,
  add column if not exists shared_credit_amount numeric(14,2) not null default 0;

alter table public.marketplace_orders drop constraint if exists marketplace_orders_payment_method_check;
alter table public.marketplace_orders add constraint marketplace_orders_payment_method_check
  check(payment_method in ('card','cash_on_delivery','credit','shared'));

create or replace function public.create_marketplace_order(payload jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare oid uuid; tracking uuid; order_no bigint; org uuid; st numeric; fee numeric; tot numeric; pm text; next_status text; item jsonb; discount_rate numeric; discount_value numeric; cash_value numeric; card_value numeric; credit_value numeric;
begin
 org=(payload->>'organization_id')::uuid;
 pm=payload->>'payment_method';
 if pm not in ('card','cash_on_delivery','credit','shared') then raise exception 'invalid_payment_method'; end if;
 if pm in ('credit','shared') and not public.is_org_member(org) then raise exception 'provider_payment_requires_org_member'; end if;
 st=(payload->>'subtotal')::numeric;
 fee=greatest(0,coalesce((payload->>'delivery_fee')::numeric,0));
 discount_rate=least(100,greatest(0,coalesce((payload->>'discount_percent')::numeric,0)));
 discount_value=round(st*discount_rate/100,2);
 tot=greatest(0,st-discount_value+fee);
 if pm='shared' then
  cash_value=least(tot,greatest(0,coalesce((payload->>'shared_cash_amount')::numeric,0)));
  card_value=least(tot-cash_value,greatest(0,coalesce((payload->>'shared_card_amount')::numeric,0)));
  credit_value=tot-cash_value-card_value;
 elsif pm='credit' then
  cash_value=0; card_value=0; credit_value=tot;
 else
  cash_value=case when pm='cash_on_delivery' then tot else 0 end;
  card_value=case when pm='card' then tot else 0 end;
  credit_value=0;
 end if;
 next_status=case when pm='cash_on_delivery' then 'pending_confirmation' else 'orders' end;
 insert into marketplace_orders(organization_id,customer_user_id,customer_name,customer_email,customer_phone,delivery_address,delivery_city,delivery_lat,delivery_lng,payment_method,payment_status,status,subtotal,discount_percent,discount_amount,delivery_fee,total,commission_amount,customer_data_unlocked,shared_cash_amount,shared_card_amount,shared_credit_amount,notes)
 values(org,auth.uid(),payload->>'customer_name',nullif(payload->>'customer_email',''),coalesce(payload->>'customer_phone',''),coalesce(payload->>'delivery_address',''),coalesce(nullif(payload->>'delivery_city',''),'Barranquilla'),(payload->>'delivery_lat')::double precision,(payload->>'delivery_lng')::double precision,pm,case when credit_value>0 then 'credit' when pm='cash_on_delivery' then 'cash_on_delivery' else 'paid' end,next_status,st,discount_rate,discount_value,fee,tot,0,true,cash_value,card_value,credit_value,payload->>'notes')
 returning id,tracking_token,order_number into oid,tracking,order_no;
 for item in select * from jsonb_array_elements(payload->'items') loop
  insert into marketplace_order_items(order_id,product_name,quantity,unit_price,total,unit_measure,unit_quantity)
  values(oid,item->>'name',(item->>'quantity')::numeric,(item->>'price')::numeric,(item->>'quantity')::numeric*(item->>'price')::numeric,coalesce(nullif(item->>'unit_measure',''),'unidad'),coalesce((item->>'unit_quantity')::numeric,1));
 end loop;
 if credit_value>0 then
  insert into credit_sales(organization_id,order_id,customer_name,customer_phone,total,paid_amount,status)
  values(org,oid,payload->>'customer_name',nullif(payload->>'customer_phone',''),credit_value,0,'active');
 end if;
 insert into order_status_history(order_id,status,actor_user_id,note) values(oid,next_status,auth.uid(),case when pm='shared' then format('Pago compartido: efectivo %s, tarjeta %s, crédito %s',cash_value,card_value,credit_value) else 'Pedido creado' end);
 return jsonb_build_object('id',oid,'order_number',order_no,'tracking_token',tracking,'status',next_status,'total',tot,'shared_cash_amount',cash_value,'shared_card_amount',card_value,'shared_credit_amount',credit_value);
end $$;

grant execute on function public.create_marketplace_order(jsonb) to anon,authenticated;
notify pgrst,'reload schema';
