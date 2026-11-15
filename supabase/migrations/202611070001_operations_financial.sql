alter table public.catalog_products
  add column if not exists average_cost numeric(14,2) not null default 0 check (average_cost >= 0);

alter table public.marketplace_order_items
  add column if not exists product_id uuid references public.catalog_products(id) on delete set null,
  add column if not exists unit_cost numeric(14,2) not null default 0 check (unit_cost >= 0);

create table if not exists public.expense_concepts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null check (length(trim(name)) between 2 and 80),
  is_active boolean not null default true,
  created_by uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  unique (organization_id, name)
);

create table if not exists public.inventory_purchases (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  purchase_date date not null default current_date,
  supplier text,
  invoice_number text,
  total numeric(14,2) not null default 0 check (total >= 0),
  created_by uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now()
);

create table if not exists public.inventory_purchase_items (
  id uuid primary key default gen_random_uuid(),
  purchase_id uuid not null references public.inventory_purchases(id) on delete cascade,
  product_id uuid not null references public.catalog_products(id) on delete restrict,
  quantity numeric(14,3) not null check (quantity > 0),
  unit_cost numeric(14,2) not null check (unit_cost >= 0),
  total numeric(14,2) not null check (total >= 0)
);

create table if not exists public.inventory_movements (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  product_id uuid not null references public.catalog_products(id) on delete cascade,
  movement_type text not null check (movement_type in ('purchase','sale','adjustment_in','adjustment_out','return')),
  quantity numeric(14,3) not null check (quantity <> 0),
  unit_cost numeric(14,2) not null default 0 check (unit_cost >= 0),
  reference_type text,
  reference_id uuid,
  note text,
  occurred_at timestamptz not null default now(),
  created_by uuid references public.profiles(id) on delete set null default auth.uid()
);

create table if not exists public.business_expenses (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  concept_id uuid not null references public.expense_concepts(id) on delete restrict,
  amount numeric(14,2) not null check (amount > 0),
  expense_date date not null default current_date,
  note text,
  created_by uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now()
);

create index if not exists inventory_purchases_org_date_idx on public.inventory_purchases(organization_id, purchase_date desc);
create index if not exists inventory_purchase_items_purchase_idx on public.inventory_purchase_items(purchase_id);
create index if not exists inventory_purchase_items_product_idx on public.inventory_purchase_items(product_id);
create index if not exists inventory_movements_org_date_idx on public.inventory_movements(organization_id, occurred_at desc);
create index if not exists inventory_movements_product_idx on public.inventory_movements(product_id);
create index if not exists business_expenses_org_date_idx on public.business_expenses(organization_id, expense_date desc);
create index if not exists business_expenses_concept_idx on public.business_expenses(concept_id);
create index if not exists expense_concepts_org_active_idx on public.expense_concepts(organization_id, is_active, name);

alter table public.expense_concepts enable row level security;
alter table public.inventory_purchases enable row level security;
alter table public.inventory_purchase_items enable row level security;
alter table public.inventory_movements enable row level security;
alter table public.business_expenses enable row level security;

drop policy if exists expense_concepts_org_access on public.expense_concepts;
create policy expense_concepts_org_access on public.expense_concepts for select to authenticated
using (public.is_org_member(organization_id) or public.is_platform_admin());
drop policy if exists expense_concepts_org_manage on public.expense_concepts;
drop policy if exists expense_concepts_org_insert on public.expense_concepts;
create policy expense_concepts_org_insert on public.expense_concepts for insert to authenticated
with check (public.is_org_manager(organization_id) or public.is_platform_admin());
drop policy if exists expense_concepts_org_update on public.expense_concepts;
create policy expense_concepts_org_update on public.expense_concepts for update to authenticated
using (public.is_org_manager(organization_id) or public.is_platform_admin())
with check (public.is_org_manager(organization_id) or public.is_platform_admin());
drop policy if exists expense_concepts_org_delete on public.expense_concepts;
create policy expense_concepts_org_delete on public.expense_concepts for delete to authenticated
using (public.is_org_manager(organization_id) or public.is_platform_admin());

drop policy if exists inventory_purchases_org_access on public.inventory_purchases;
create policy inventory_purchases_org_access on public.inventory_purchases for select to authenticated
using (public.is_org_member(organization_id) or public.is_platform_admin());
drop policy if exists inventory_purchase_items_org_access on public.inventory_purchase_items;
create policy inventory_purchase_items_org_access on public.inventory_purchase_items for select to authenticated
using (exists (
  select 1 from public.inventory_purchases p
  where p.id = purchase_id and (public.is_org_member(p.organization_id) or public.is_platform_admin())
));
drop policy if exists inventory_movements_org_access on public.inventory_movements;
create policy inventory_movements_org_access on public.inventory_movements for select to authenticated
using (public.is_org_member(organization_id) or public.is_platform_admin());

drop policy if exists business_expenses_org_access on public.business_expenses;
create policy business_expenses_org_access on public.business_expenses for select to authenticated
using (public.is_org_member(organization_id) or public.is_platform_admin());
drop policy if exists business_expenses_org_insert on public.business_expenses;
create policy business_expenses_org_insert on public.business_expenses for insert to authenticated
with check (
  (public.is_org_member(organization_id) or public.is_platform_admin())
  and exists (select 1 from public.expense_concepts c where c.id = concept_id and c.organization_id = organization_id and c.is_active)
);
drop policy if exists business_expenses_org_update on public.business_expenses;
create policy business_expenses_org_update on public.business_expenses for update to authenticated
using (public.is_org_manager(organization_id) or public.is_platform_admin())
with check (public.is_org_manager(organization_id) or public.is_platform_admin());

grant select,insert,update,delete on public.expense_concepts to authenticated;
grant select on public.inventory_purchases,public.inventory_purchase_items,public.inventory_movements to authenticated;
grant select,insert,update on public.business_expenses to authenticated;

create or replace function public.register_inventory_purchase(
  target_org uuid,
  purchase_on date,
  supplier_name text,
  invoice text,
  items jsonb
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  purchase_id uuid;
  item jsonb;
  product public.catalog_products%rowtype;
  item_qty numeric;
  item_cost numeric;
  purchase_total numeric := 0;
  new_average numeric;
begin
  if auth.uid() is null or not (public.is_org_member(target_org) or public.is_platform_admin()) then
    raise exception 'not_authorized';
  end if;
  if items is null or jsonb_typeof(items) <> 'array' or jsonb_array_length(items) = 0 then
    raise exception 'purchase_requires_items';
  end if;

  insert into public.inventory_purchases(organization_id,purchase_date,supplier,invoice_number,created_by)
  values(target_org,coalesce(purchase_on,current_date),nullif(trim(supplier_name),''),nullif(trim(invoice),''),auth.uid())
  returning id into purchase_id;

  for item in select * from jsonb_array_elements(items) loop
    select * into product from public.catalog_products
    where id=(item->>'product_id')::uuid and organization_id=target_org
    for update;
    if product.id is null then raise exception 'invalid_product'; end if;
    item_qty=(item->>'quantity')::numeric;
    item_cost=(item->>'unit_cost')::numeric;
    if item_qty <= 0 or item_qty <> trunc(item_qty) or item_cost < 0 then raise exception 'invalid_purchase_item'; end if;

    purchase_total := purchase_total + round(item_qty*item_cost,2);
    new_average := case when product.stock + item_qty > 0
      then round(((product.stock*product.average_cost)+(item_qty*item_cost))/(product.stock+item_qty),2)
      else item_cost end;

    insert into public.inventory_purchase_items(purchase_id,product_id,quantity,unit_cost,total)
    values(purchase_id,product.id,item_qty,item_cost,round(item_qty*item_cost,2));
    insert into public.inventory_movements(organization_id,product_id,movement_type,quantity,unit_cost,reference_type,reference_id,occurred_at,created_by)
    values(target_org,product.id,'purchase',item_qty,item_cost,'purchase',purchase_id,coalesce(purchase_on,current_date)::timestamptz,auth.uid());
    update public.catalog_products set stock=stock+item_qty::integer,average_cost=new_average,updated_at=now() where id=product.id;
  end loop;

  update public.inventory_purchases set total=purchase_total where id=purchase_id;
  return purchase_id;
end $$;

revoke all on function public.register_inventory_purchase(uuid,date,text,text,jsonb) from public,anon;
grant execute on function public.register_inventory_purchase(uuid,date,text,text,jsonb) to authenticated;

create or replace function public.capture_order_item_cost()
returns trigger language plpgsql security invoker set search_path=public as $$
declare order_org uuid; catalog_product public.catalog_products%rowtype;
begin
  select organization_id into order_org from public.marketplace_orders where id=new.order_id;
  select * into catalog_product from public.catalog_products
  where organization_id=order_org and lower(name)=lower(new.product_name)
  order by created_at desc limit 1;
  if catalog_product.id is not null then
    new.product_id := catalog_product.id;
    new.unit_cost := catalog_product.average_cost;
  end if;
  return new;
end $$;

drop trigger if exists marketplace_order_item_cost_trigger on public.marketplace_order_items;
create trigger marketplace_order_item_cost_trigger before insert on public.marketplace_order_items
for each row execute function public.capture_order_item_cost();

create or replace function public.get_provider_financial_summary(target_org uuid,date_from date,date_to date)
returns jsonb language plpgsql stable security invoker set search_path=public as $$
declare result jsonb;
begin
  if auth.uid() is null or not (public.is_org_member(target_org) or public.is_platform_admin()) then
    raise exception 'not_authorized';
  end if;
  if date_to < date_from then raise exception 'invalid_date_range'; end if;

  with filtered_orders as (
    select * from public.marketplace_orders
    where organization_id=target_org
      and (created_at at time zone 'America/Bogota')::date between date_from and date_to
      and status not in ('cancelled','returned')
  ), sales as (
    select
      coalesce(sum(total),0) total_sales,
      coalesce(sum(case when payment_method='cash_on_delivery' then total when payment_method='shared' then shared_cash_amount else 0 end),0) cash_sales,
      coalesce(sum(case when payment_method='card' then total when payment_method='shared' then shared_card_amount else 0 end),0) transfer_sales,
      coalesce(sum(case when payment_method='credit' then total when payment_method='shared' then shared_credit_amount else 0 end),0) credit_sales
    from filtered_orders
  ), costs as (
    select coalesce(sum(i.quantity*i.unit_cost),0) cost_of_sales
    from public.marketplace_order_items i join filtered_orders o on o.id=i.order_id
  ), expenses as (
    select coalesce(sum(amount),0) expense_total from public.business_expenses
    where organization_id=target_org and expense_date between date_from and date_to
  ), purchases as (
    select coalesce(sum(total),0) purchase_total from public.inventory_purchases
    where organization_id=target_org and purchase_date between date_from and date_to
  )
  select jsonb_build_object(
    'total_sales',sales.total_sales,'cash_sales',sales.cash_sales,'transfer_sales',sales.transfer_sales,
    'credit_sales',sales.credit_sales,'cost_of_sales',costs.cost_of_sales,'expenses',expenses.expense_total,
    'purchases',purchases.purchase_total,'gross_profit',sales.total_sales-costs.cost_of_sales,
    'net_profit',sales.total_sales-costs.cost_of_sales-expenses.expense_total
  ) into result from sales,costs,expenses,purchases;
  return result;
end $$;

revoke all on function public.get_provider_financial_summary(uuid,date,date) from public,anon;
grant execute on function public.get_provider_financial_summary(uuid,date,date) to authenticated;

notify pgrst,'reload schema';
