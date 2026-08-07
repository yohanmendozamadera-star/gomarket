create table if not exists public.catalog_products(
 id uuid primary key default gen_random_uuid(), organization_id uuid not null references public.organizations(id) on delete cascade,
 name text not null, category text not null, description text, price numeric(14,2) not null check(price>=0), stock integer not null default 0 check(stock>=0),
 image_url text, is_active boolean not null default true, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists public.service_cities(
 id uuid primary key default gen_random_uuid(), name text not null unique, is_active boolean not null default true, created_at timestamptz not null default now()
);
insert into public.service_cities(name) values('Barranquilla'),('Soledad') on conflict(name) do nothing;
alter table public.marketplace_orders add column if not exists delivery_lat double precision;
alter table public.marketplace_orders add column if not exists delivery_lng double precision;
alter table public.marketplace_orders add column if not exists delivered_lat double precision;
alter table public.marketplace_orders add column if not exists delivered_lng double precision;
alter table public.marketplace_orders add column if not exists return_reason text;
alter table public.catalog_products enable row level security;
alter table public.service_cities enable row level security;
create policy "catalog_public_read" on public.catalog_products for select to anon,authenticated using(is_active or is_org_member(organization_id));
create policy "catalog_provider_manage" on public.catalog_products for all to authenticated using(is_org_manager(organization_id)) with check(is_org_manager(organization_id));
create policy "cities_public_read" on public.service_cities for select to anon,authenticated using(is_active);
create policy "cities_admin_manage" on public.service_cities for all to authenticated using(is_super_admin()) with check(is_super_admin());
grant select on public.catalog_products,public.service_cities to anon,authenticated;
grant insert,update,delete on public.catalog_products,public.service_cities to authenticated;

create or replace function public.provider_update_order(target_order uuid,next_status text,status_note text default null,delivery_lat double precision default null,delivery_lng double precision default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare ord marketplace_orders%rowtype; bal numeric; unlock boolean;
begin
 select * into ord from marketplace_orders where id=target_order for update;
 if ord.id is null or not is_org_manager(ord.organization_id) then raise exception 'not_authorized'; end if;
 if next_status='orders' and ord.status<>'pending_confirmation' then raise exception 'invalid_transition'; end if;
 if next_status in ('confirmed','preparing','dispatched','out_for_delivery') and not ord.customer_data_unlocked then
  select balance into bal from wallet_accounts where organization_id=ord.organization_id for update;
  if coalesce(bal,0)<ord.commission_amount then raise exception 'insufficient_coins'; end if;
  update wallet_accounts set balance=balance-ord.commission_amount,updated_at=now() where organization_id=ord.organization_id returning balance into bal;
  insert into wallet_transactions(organization_id,order_id,kind,amount,balance_after,description) values(ord.organization_id,ord.id,'commission',-ord.commission_amount,bal,'Comisión GoMarket 9,5%');
  unlock=true;
 else unlock=ord.customer_data_unlocked; end if;
 update marketplace_orders set status=next_status,customer_data_unlocked=unlock,return_reason=case when next_status='returned' then status_note else return_reason end,
 delivered_lat=case when next_status='delivered' then delivery_lat else delivered_lat end,delivered_lng=case when next_status='delivered' then delivery_lng else delivered_lng end,updated_at=now() where id=target_order;
 insert into order_status_history(order_id,status,actor_user_id,note) values(target_order,next_status,auth.uid(),status_note);
 return jsonb_build_object('status',next_status,'unlocked',unlock,'balance',bal);
end $$;
grant execute on function public.provider_update_order(uuid,text,text,double precision,double precision) to authenticated;
create or replace function public.create_marketplace_order(payload jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare oid uuid; org uuid; st numeric; fee numeric; tot numeric; comm numeric; pm text; next_status text; item jsonb;
begin
 org=(payload->>'organization_id')::uuid;pm=payload->>'payment_method';st=(payload->>'subtotal')::numeric;fee=coalesce((payload->>'delivery_fee')::numeric,0);tot=st+fee;comm=round(st*.095,2);
 next_status=case when pm='cash_on_delivery' then 'pending_confirmation' else 'orders' end;
 insert into marketplace_orders(organization_id,customer_user_id,customer_name,customer_email,customer_phone,delivery_address,delivery_city,delivery_lat,delivery_lng,payment_method,payment_status,status,subtotal,delivery_fee,total,commission_amount,notes)
 values(org,auth.uid(),payload->>'customer_name',payload->>'customer_email',payload->>'customer_phone',payload->>'delivery_address',payload->>'delivery_city',(payload->>'delivery_lat')::double precision,(payload->>'delivery_lng')::double precision,pm,case when pm='card' then 'paid' else 'cash_on_delivery' end,next_status,st,fee,tot,comm,payload->>'notes') returning id into oid;
 for item in select * from jsonb_array_elements(payload->'items') loop insert into marketplace_order_items(order_id,product_name,quantity,unit_price,total) values(oid,item->>'name',(item->>'quantity')::int,(item->>'price')::numeric,(item->>'quantity')::int*(item->>'price')::numeric);end loop;
 insert into order_status_history(order_id,status,actor_user_id,note) values(oid,next_status,auth.uid(),'Pedido creado');
 return jsonb_build_object('id',oid,'status',next_status,'total',tot,'commission',comm);
end $$;
grant execute on function public.create_marketplace_order(jsonb) to anon,authenticated;
notify pgrst,'reload schema';
