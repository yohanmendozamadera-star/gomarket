-- GoMarket marketplace: provider applications, checkout, orders, wallets and commissions.
create table if not exists public.provider_applications (
  id uuid primary key default gen_random_uuid(), user_id uuid not null references public.profiles(id),
  business_name text not null, tax_id text not null, contact_name text not null, phone text not null,
  city text not null, address text not null, status text not null default 'pending' check(status in ('pending','approved','rejected')),
  organization_id uuid references public.organizations(id), created_at timestamptz not null default now()
);

create table if not exists public.wallet_accounts (
  organization_id uuid primary key references public.organizations(id) on delete cascade,
  balance numeric(14,2) not null default 0 check(balance>=0), updated_at timestamptz not null default now()
);

create table if not exists public.wallet_transactions (
  id uuid primary key default gen_random_uuid(), organization_id uuid not null references public.organizations(id) on delete cascade,
  order_id uuid, kind text not null check(kind in ('recharge','commission','refund','adjustment')),
  amount numeric(14,2) not null, balance_after numeric(14,2) not null, description text, created_at timestamptz not null default now()
);

create table if not exists public.marketplace_orders (
  id uuid primary key default gen_random_uuid(), order_number bigint generated always as identity unique,
  organization_id uuid not null references public.organizations(id), customer_user_id uuid references public.profiles(id),
  customer_name text not null, customer_email text, customer_phone text not null, delivery_address text not null,
  delivery_city text not null, payment_method text not null check(payment_method in ('card','cash_on_delivery')),
  payment_status text not null check(payment_status in ('pending','paid','failed','cash_on_delivery')),
  status text not null check(status in ('pending_confirmation','orders','confirmed','preparing','dispatched','out_for_delivery','delivered','returned')),
  subtotal numeric(14,2) not null, delivery_fee numeric(14,2) not null default 0, total numeric(14,2) not null,
  commission_rate numeric(6,4) not null default .095, commission_amount numeric(14,2) not null,
  customer_data_unlocked boolean not null default false, notes text, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);

alter table public.wallet_transactions add constraint wallet_transactions_order_fk foreign key(order_id) references public.marketplace_orders(id) on delete set null;

create table if not exists public.marketplace_order_items (
  id uuid primary key default gen_random_uuid(), order_id uuid not null references public.marketplace_orders(id) on delete cascade,
  product_name text not null, quantity integer not null check(quantity>0), unit_price numeric(14,2) not null, total numeric(14,2) not null
);

create table if not exists public.order_status_history (
  id bigint generated always as identity primary key, order_id uuid not null references public.marketplace_orders(id) on delete cascade,
  status text not null, actor_user_id uuid references public.profiles(id), note text, created_at timestamptz not null default now()
);

create table if not exists public.order_reviews (
  id uuid primary key default gen_random_uuid(), order_id uuid not null unique references public.marketplace_orders(id) on delete cascade,
  customer_user_id uuid references public.profiles(id), rating integer not null check(rating between 1 and 5), comment text, created_at timestamptz not null default now()
);

create index if not exists marketplace_orders_org_status_idx on public.marketplace_orders(organization_id,status,created_at desc);
create index if not exists marketplace_orders_customer_idx on public.marketplace_orders(customer_user_id,created_at desc);

create or replace function public.submit_provider_application(business_name text,tax_id text,contact_name text,phone text,city text,address text)
returns uuid language plpgsql security definer set search_path=public as $$
declare aid uuid;
begin
  if auth.uid() is null then raise exception 'authentication_required'; end if;
  insert into provider_applications(user_id,business_name,tax_id,contact_name,phone,city,address)
  values(auth.uid(),business_name,tax_id,contact_name,phone,city,address) returning id into aid;
  return aid;
end $$;

create or replace function public.create_marketplace_order(payload jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare oid uuid; org uuid; st numeric; fee numeric; tot numeric; comm numeric; pm text; next_status text; item jsonb;
begin
  org=(payload->>'organization_id')::uuid; pm=payload->>'payment_method'; st=(payload->>'subtotal')::numeric; fee=coalesce((payload->>'delivery_fee')::numeric,0); tot=st+fee; comm=round(st*.095,2);
  next_status=case when pm='cash_on_delivery' then 'pending_confirmation' else 'orders' end;
  insert into marketplace_orders(organization_id,customer_user_id,customer_name,customer_email,customer_phone,delivery_address,delivery_city,payment_method,payment_status,status,subtotal,delivery_fee,total,commission_amount,notes)
  values(org,auth.uid(),payload->>'customer_name',payload->>'customer_email',payload->>'customer_phone',payload->>'delivery_address',payload->>'delivery_city',pm,case when pm='card' then 'paid' else 'cash_on_delivery' end,next_status,st,fee,tot,comm,payload->>'notes') returning id into oid;
  for item in select * from jsonb_array_elements(payload->'items') loop
    insert into marketplace_order_items(order_id,product_name,quantity,unit_price,total) values(oid,item->>'name',(item->>'quantity')::int,(item->>'price')::numeric,(item->>'quantity')::int*(item->>'price')::numeric);
  end loop;
  insert into order_status_history(order_id,status,actor_user_id,note) values(oid,next_status,auth.uid(),'Pedido creado');
  return jsonb_build_object('id',oid,'status',next_status,'total',tot,'commission',comm);
end $$;

create or replace function public.recharge_provider_wallet(target_org uuid,amount numeric)
returns numeric language plpgsql security definer set search_path=public as $$
declare bal numeric;
begin
  if not is_org_manager(target_org) then raise exception 'not_authorized'; end if;
  if amount<=0 then raise exception 'invalid_amount'; end if;
  insert into wallet_accounts(organization_id,balance) values(target_org,amount)
  on conflict(organization_id) do update set balance=wallet_accounts.balance+excluded.balance,updated_at=now() returning balance into bal;
  insert into wallet_transactions(organization_id,kind,amount,balance_after,description) values(target_org,'recharge',amount,bal,'Recarga de monedas GoMarket');
  return bal;
end $$;

create or replace function public.provider_update_order(target_order uuid,next_status text)
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
  update marketplace_orders set status=next_status,customer_data_unlocked=unlock,updated_at=now() where id=target_order;
  insert into order_status_history(order_id,status,actor_user_id) values(target_order,next_status,auth.uid());
  return jsonb_build_object('status',next_status,'unlocked',unlock,'balance',bal);
end $$;

create or replace function public.get_provider_orders(target_org uuid)
returns table(id uuid,order_number bigint,status text,payment_method text,payment_status text,total numeric,commission_amount numeric,customer_data_unlocked boolean,customer_name text,customer_phone text,delivery_address text,delivery_city text,created_at timestamptz)
language sql stable security definer set search_path=public as $$
 select o.id,o.order_number,o.status,o.payment_method,o.payment_status,o.total,o.commission_amount,o.customer_data_unlocked,
 case when o.customer_data_unlocked then o.customer_name else 'Datos protegidos' end,
 case when o.customer_data_unlocked then o.customer_phone else '••••••••••' end,
 case when o.customer_data_unlocked then o.delivery_address else 'Disponible al descontar comisión' end,
 case when o.customer_data_unlocked then o.delivery_city else 'Protegida' end,o.created_at
 from marketplace_orders o where o.organization_id=target_org and is_org_member(target_org) order by o.created_at desc
$$;

create or replace function public.get_admin_marketplace_overview()
returns table(id uuid,order_number bigint,organization_name text,status text,payment_method text,total numeric,commission_amount numeric,customer_name text,created_at timestamptz)
language sql stable security definer set search_path=public as $$
 select o.id,o.order_number,g.name,o.status,o.payment_method,o.total,o.commission_amount,o.customer_name,o.created_at
 from marketplace_orders o join organizations g on g.id=o.organization_id where is_platform_admin() order by o.created_at desc
$$;

create or replace function public.review_delivered_order(target_order uuid,rating int,comment text)
returns uuid language plpgsql security definer set search_path=public as $$ declare rid uuid; begin
 if rating<1 or rating>5 then raise exception 'invalid_rating'; end if;
 insert into order_reviews(order_id,customer_user_id,rating,comment) select id,auth.uid(),rating,comment from marketplace_orders where id=target_order and status='delivered' returning id into rid;
 return rid; end $$;

alter table public.provider_applications enable row level security;
alter table public.wallet_accounts enable row level security;
alter table public.wallet_transactions enable row level security;
alter table public.marketplace_orders enable row level security;
alter table public.marketplace_order_items enable row level security;
alter table public.order_status_history enable row level security;
alter table public.order_reviews enable row level security;

grant execute on function public.submit_provider_application(text,text,text,text,text,text) to authenticated;
grant execute on function public.create_marketplace_order(jsonb) to anon,authenticated;
grant execute on function public.recharge_provider_wallet(uuid,numeric) to authenticated;
grant execute on function public.provider_update_order(uuid,text) to authenticated;
grant execute on function public.get_provider_orders(uuid) to authenticated;
grant execute on function public.get_admin_marketplace_overview() to authenticated;
grant execute on function public.review_delivered_order(uuid,int,text) to authenticated;
grant select on public.provider_applications,public.wallet_accounts,public.wallet_transactions,public.marketplace_orders,public.marketplace_order_items,public.order_status_history,public.order_reviews to authenticated;

create policy "provider_app_read" on public.provider_applications for select to authenticated using(user_id=auth.uid() or is_platform_admin());
create policy "wallet_read" on public.wallet_accounts for select to authenticated using(is_org_member(organization_id));
create policy "wallet_tx_read" on public.wallet_transactions for select to authenticated using(is_org_member(organization_id));
create policy "orders_customer_read" on public.marketplace_orders for select to authenticated using(customer_user_id=auth.uid() or is_org_member(organization_id));
create policy "order_items_read" on public.marketplace_order_items for select to authenticated using(exists(select 1 from marketplace_orders o where o.id=order_id and (o.customer_user_id=auth.uid() or is_org_member(o.organization_id))));
create policy "history_read" on public.order_status_history for select to authenticated using(exists(select 1 from marketplace_orders o where o.id=order_id and (o.customer_user_id=auth.uid() or is_org_member(o.organization_id))));
create policy "reviews_read" on public.order_reviews for select to authenticated using(true);

notify pgrst,'reload schema';
