alter table public.marketplace_order_items alter column quantity type numeric(12,2) using quantity::numeric;
alter table public.marketplace_orders add column if not exists delivery_photo_path text;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('delivery-evidence','delivery-evidence',false,5242880,array['image/jpeg','image/png','image/webp'])
on conflict(id) do update set file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;

drop policy if exists "Managers upload delivery evidence" on storage.objects;
create policy "Managers upload delivery evidence" on storage.objects for insert to authenticated
with check(bucket_id='delivery-evidence' and public.is_org_manager(((storage.foldername(name))[1])::uuid));

drop policy if exists "Managers view delivery evidence" on storage.objects;
create policy "Managers view delivery evidence" on storage.objects for select to authenticated
using(bucket_id='delivery-evidence' and (public.is_org_manager(((storage.foldername(name))[1])::uuid) or public.is_platform_admin()));

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
  values(oid,item->>'name',(item->>'quantity')::numeric,(item->>'price')::numeric,(item->>'quantity')::numeric*(item->>'price')::numeric,coalesce(nullif(item->>'unit_measure',''),'unidad'),coalesce((item->>'unit_quantity')::numeric,1));
 end loop;
 insert into order_status_history(order_id,status,actor_user_id,note) values(oid,next_status,auth.uid(),'Pedido creado');
 return jsonb_build_object('id',oid,'order_number',order_no,'tracking_token',tracking,'status',next_status,'total',tot,'commission',comm);
end $$;

create or replace function public.get_order_timeline(target_order uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare ord marketplace_orders%rowtype;
begin
 select * into ord from marketplace_orders where id=target_order;
 if ord.id is null or not (is_org_manager(ord.organization_id) or is_platform_admin()) then raise exception 'not_authorized'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object(
   'status',h.status,'note',h.note,'created_at',h.created_at,
   'user_name',coalesce(p.full_name,p.email,'Sistema'),'user_email',p.email
 ) order by h.created_at desc)
 from order_status_history h left join profiles p on p.id=h.actor_user_id where h.order_id=target_order),'[]'::jsonb);
end $$;

create or replace function public.deliver_marketplace_order(target_order uuid,evidence_path text,new_delivery_lat double precision default null,new_delivery_lng double precision default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare ord marketplace_orders%rowtype;
begin
 select * into ord from marketplace_orders where id=target_order for update;
 if ord.id is null or not is_org_manager(ord.organization_id) then raise exception 'not_authorized'; end if;
 if ord.status<>'out_for_delivery' then raise exception 'delivery_not_allowed_in_%',ord.status; end if;
 if nullif(trim(evidence_path),'') is null then raise exception 'delivery_photo_required'; end if;
 update marketplace_orders set status='delivered',delivery_photo_path=evidence_path,delivered_at=now(),delivered_lat=new_delivery_lat,delivered_lng=new_delivery_lng,updated_at=now() where id=target_order;
 insert into order_status_history(order_id,status,actor_user_id,note) values(target_order,'delivered',auth.uid(),'Pedido entregado con fotografía de evidencia');
 return jsonb_build_object('status','delivered','updated',true);
end $$;

grant execute on function public.create_marketplace_order(jsonb) to anon,authenticated;
grant execute on function public.get_order_timeline(uuid) to authenticated;
grant execute on function public.deliver_marketplace_order(uuid,text,double precision,double precision) to authenticated;
notify pgrst,'reload schema';
