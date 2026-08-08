alter table public.marketplace_order_items
  add column if not exists unit_measure text,
  add column if not exists unit_quantity numeric(12,3);

update public.marketplace_order_items i
set unit_measure=coalesce((
      select c.unit_measure from public.catalog_products c
      join public.marketplace_orders o on o.organization_id=c.organization_id
      where o.id=i.order_id and lower(trim(c.name))=lower(trim(i.product_name))
      order by c.updated_at desc limit 1
    ),'unidad'),
    unit_quantity=coalesce((
      select c.unit_quantity from public.catalog_products c
      join public.marketplace_orders o on o.organization_id=c.organization_id
      where o.id=i.order_id and lower(trim(c.name))=lower(trim(i.product_name))
      order by c.updated_at desc limit 1
    ),1)
where i.unit_measure is null or i.unit_quantity is null;

update public.marketplace_order_items
set unit_measure=coalesce(unit_measure,'unidad'),
    unit_quantity=coalesce(unit_quantity,1);

alter table public.marketplace_order_items alter column unit_measure set default 'unidad';
alter table public.marketplace_order_items alter column unit_measure set not null;
alter table public.marketplace_order_items alter column unit_quantity set default 1;
alter table public.marketplace_order_items alter column unit_quantity set not null;

create or replace function public.create_marketplace_order(payload jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare oid uuid; tracking uuid; order_no bigint; org uuid; st numeric; fee numeric; tot numeric; comm numeric; pm text; next_status text; item jsonb;
begin
 org=(payload->>'organization_id')::uuid;pm=payload->>'payment_method';st=(payload->>'subtotal')::numeric;fee=coalesce((payload->>'delivery_fee')::numeric,0);tot=st+fee;comm=round(st*.095,2);
 next_status=case when pm='cash_on_delivery' then 'pending_confirmation' else 'orders' end;
 insert into marketplace_orders(organization_id,customer_user_id,customer_name,customer_email,customer_phone,delivery_address,delivery_city,delivery_lat,delivery_lng,payment_method,payment_status,status,subtotal,delivery_fee,total,commission_amount,notes)
 values(org,auth.uid(),payload->>'customer_name',nullif(payload->>'customer_email',''),payload->>'customer_phone',payload->>'delivery_address',payload->>'delivery_city',(payload->>'delivery_lat')::double precision,(payload->>'delivery_lng')::double precision,pm,case when pm='card' then 'paid' else 'cash_on_delivery' end,next_status,st,fee,tot,comm,payload->>'notes') returning id,tracking_token,order_number into oid,tracking,order_no;
 for item in select * from jsonb_array_elements(payload->'items') loop
  insert into marketplace_order_items(order_id,product_name,quantity,unit_price,total,unit_measure,unit_quantity)
  values(oid,item->>'name',(item->>'quantity')::int,(item->>'price')::numeric,(item->>'quantity')::int*(item->>'price')::numeric,coalesce(nullif(item->>'unit_measure',''),'unidad'),coalesce((item->>'unit_quantity')::numeric,1));
 end loop;
 insert into order_status_history(order_id,status,actor_user_id,note) values(oid,next_status,auth.uid(),'Pedido creado');
 return jsonb_build_object('id',oid,'order_number',order_no,'tracking_token',tracking,'status',next_status,'total',tot,'commission',comm);
end $$;

create or replace function public.get_provider_order_detail(target_order uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare ord marketplace_orders%rowtype; result jsonb;
begin
  select * into ord from marketplace_orders where id=target_order;
  if ord.id is null or not is_org_manager(ord.organization_id) then raise exception 'not_authorized'; end if;
  if not ord.customer_data_unlocked then raise exception 'customer_data_locked'; end if;
  select jsonb_build_object(
    'id',ord.id,'order_number',ord.order_number,'customer_name',ord.customer_name,'customer_phone',ord.customer_phone,
    'delivery_address',ord.delivery_address,'delivery_city',ord.delivery_city,'notes',ord.notes,
    'payment_method',ord.payment_method,'status',ord.status,'subtotal',ord.subtotal,'delivery_fee',ord.delivery_fee,'total',ord.total,
    'return_reason',ord.return_reason,'return_notes',ord.return_notes,'return_photo_path',ord.return_photo_path,
    'items',coalesce((select jsonb_agg(jsonb_build_object('product_name',i.product_name,'quantity',i.quantity,'unit_price',i.unit_price,'total',i.total,'unit_measure',i.unit_measure,'unit_quantity',i.unit_quantity) order by i.product_name) from marketplace_order_items i where i.order_id=ord.id),'[]'::jsonb)
  ) into result;
  return result;
end $$;

grant execute on function public.create_marketplace_order(jsonb) to anon,authenticated;
grant execute on function public.get_provider_order_detail(uuid) to authenticated;
notify pgrst,'reload schema';
