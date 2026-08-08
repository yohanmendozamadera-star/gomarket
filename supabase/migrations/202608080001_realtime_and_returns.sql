alter table public.marketplace_orders
  add column if not exists return_notes text,
  add column if not exists return_photo_path text;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('return-evidence','return-evidence',false,5242880,array['image/jpeg','image/png','image/webp'])
on conflict(id) do update set file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;

drop policy if exists "Managers upload return evidence" on storage.objects;
create policy "Managers upload return evidence" on storage.objects for insert to authenticated
with check(bucket_id='return-evidence' and public.is_org_manager(((storage.foldername(name))[1])::uuid));

drop policy if exists "Managers view return evidence" on storage.objects;
create policy "Managers view return evidence" on storage.objects for select to authenticated
using(bucket_id='return-evidence' and public.is_org_manager(((storage.foldername(name))[1])::uuid));

create or replace function public.return_marketplace_order(
  target_order uuid,
  selected_reason text,
  return_observation text default null,
  evidence_path text default null
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare ord marketplace_orders%rowtype;
begin
  select * into ord from marketplace_orders where id=target_order for update;
  if ord.id is null or not is_org_manager(ord.organization_id) then raise exception 'not_authorized'; end if;
  if ord.status not in ('dispatched','out_for_delivery') then raise exception 'return_not_allowed_in_%',ord.status; end if;
  if selected_reason not in ('Cliente Rechaza','Cliente no tiene Dinero','Cliente no pidio nada','No es lo que él pidio','Direccion incorrecta','Nadie Para Recibir') then raise exception 'invalid_return_reason'; end if;
  if nullif(trim(evidence_path),'') is null then raise exception 'return_photo_required'; end if;
  update marketplace_orders set status='returned',return_reason=selected_reason,
    return_notes=nullif(trim(return_observation),''),return_photo_path=evidence_path,updated_at=now()
  where id=target_order;
  insert into order_status_history(order_id,status,actor_user_id,note)
  values(target_order,'returned',auth.uid(),concat(selected_reason,case when nullif(trim(return_observation),'') is null then '' else ': '||trim(return_observation) end));
  return jsonb_build_object('status','returned','updated',true);
end $$;

grant execute on function public.return_marketplace_order(uuid,text,text,text) to authenticated;

create or replace function public.set_provider_order_status(target_order uuid,next_status text,status_note text default null,new_delivery_lat double precision default null,new_delivery_lng double precision default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare ord marketplace_orders%rowtype; allowed boolean:=false;
begin
  select * into ord from marketplace_orders where id=target_order for update;
  if ord.id is null or not is_org_manager(ord.organization_id) then raise exception 'not_authorized'; end if;
  allowed:=case
    when ord.status='pending_confirmation' then next_status in ('orders','cancelled')
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
  insert into order_status_history(order_id,status,actor_user_id,note) values(target_order,next_status,auth.uid(),status_note);
  return jsonb_build_object('status',next_status,'updated',true);
end $$;

grant execute on function public.set_provider_order_status(uuid,text,text,double precision,double precision) to authenticated;

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
    'items',coalesce((select jsonb_agg(jsonb_build_object('product_name',i.product_name,'quantity',i.quantity,'unit_price',i.unit_price,'total',i.total) order by i.product_name) from marketplace_order_items i where i.order_id=ord.id),'[]'::jsonb)
  ) into result;
  return result;
end $$;

grant execute on function public.get_provider_order_detail(uuid) to authenticated;

do $$ begin
  alter publication supabase_realtime add table public.marketplace_orders;
exception when duplicate_object then null;
end $$;

notify pgrst,'reload schema';
