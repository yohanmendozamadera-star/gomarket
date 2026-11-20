create table if not exists public.business_suppliers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null check (length(trim(name)) between 2 and 120),
  tax_id text,
  contact_name text,
  phone text,
  email text,
  payment_terms_days integer not null default 0 check (payment_terms_days between 0 and 365),
  is_active boolean not null default true,
  created_by uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, name)
);

alter table public.inventory_purchases
  add column if not exists supplier_id uuid references public.business_suppliers(id) on delete set null,
  add column if not exists payment_method text not null default 'cash' check (payment_method in ('cash','credit','partial')),
  add column if not exists paid_amount numeric(14,2) not null default 0 check (paid_amount >= 0),
  add column if not exists due_date date,
  add column if not exists payment_status text not null default 'paid' check (payment_status in ('pending','partial','paid','cancelled')),
  add column if not exists payment_note text;

update public.inventory_purchases
set paid_amount=total,payment_method='cash',payment_status='paid'
where paid_amount=0 and total>0 and payment_status='paid';

create table if not exists public.supplier_payments (
  id uuid primary key default gen_random_uuid(),
  purchase_id uuid not null references public.inventory_purchases(id) on delete restrict,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  amount numeric(14,2) not null check (amount > 0),
  method text not null check (method in ('cash','transfer','card','other')),
  payment_date date not null default current_date,
  reference text,
  note text,
  created_by uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now()
);

create index if not exists business_suppliers_org_name_idx on public.business_suppliers(organization_id,name);
create index if not exists inventory_purchases_payables_idx on public.inventory_purchases(organization_id,payment_status,due_date);
create index if not exists supplier_payments_purchase_idx on public.supplier_payments(purchase_id,payment_date desc);
create index if not exists supplier_payments_org_date_idx on public.supplier_payments(organization_id,payment_date desc);

alter table public.business_suppliers enable row level security;
alter table public.supplier_payments enable row level security;

drop policy if exists business_suppliers_org_select on public.business_suppliers;
create policy business_suppliers_org_select on public.business_suppliers for select to authenticated
using ((select public.is_org_member(organization_id)) or (select public.is_platform_admin()));
drop policy if exists business_suppliers_org_insert on public.business_suppliers;
create policy business_suppliers_org_insert on public.business_suppliers for insert to authenticated
with check ((select public.is_org_manager(organization_id)) or (select public.is_platform_admin()));
drop policy if exists business_suppliers_org_update on public.business_suppliers;
create policy business_suppliers_org_update on public.business_suppliers for update to authenticated
using ((select public.is_org_manager(organization_id)) or (select public.is_platform_admin()))
with check ((select public.is_org_manager(organization_id)) or (select public.is_platform_admin()));

drop policy if exists supplier_payments_org_select on public.supplier_payments;
create policy supplier_payments_org_select on public.supplier_payments for select to authenticated
using ((select public.is_org_member(organization_id)) or (select public.is_platform_admin()));

revoke all on table public.business_suppliers,public.supplier_payments from anon,authenticated;
grant select,insert,update on table public.business_suppliers to authenticated;
grant select on table public.supplier_payments to authenticated;

create or replace function public.register_inventory_purchase_payable(
  target_org uuid,
  purchase_on date,
  supplier_target uuid,
  supplier_name text,
  invoice text,
  pay_method text,
  initial_payment numeric,
  payment_due date,
  payment_note text,
  items jsonb
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  purchase_id uuid;
  item jsonb;
  product public.catalog_products%rowtype;
  item_qty numeric;
  item_cost numeric;
  purchase_total numeric := 0;
  new_average numeric;
  paid_value numeric := coalesce(initial_payment,0);
  supplier_label text;
begin
  if auth.uid() is null or not (public.is_org_member(target_org) or public.is_platform_admin()) then raise exception 'not_authorized'; end if;
  if pay_method not in ('cash','credit','partial') then raise exception 'invalid_payment_method'; end if;
  if items is null or jsonb_typeof(items)<>'array' or jsonb_array_length(items)=0 then raise exception 'purchase_requires_items'; end if;
  if supplier_target is not null then
    select name into supplier_label from public.business_suppliers where id=supplier_target and organization_id=target_org and is_active;
    if supplier_label is null then raise exception 'invalid_supplier'; end if;
  else
    supplier_label := nullif(trim(supplier_name),'');
  end if;
  if pay_method<>'cash' and supplier_label is null then raise exception 'credit_requires_supplier'; end if;

  insert into public.inventory_purchases(organization_id,purchase_date,supplier_id,supplier,invoice_number,payment_method,paid_amount,due_date,payment_status,payment_note,created_by)
  values(target_org,coalesce(purchase_on,current_date),supplier_target,supplier_label,nullif(trim(invoice),''),pay_method,0,payment_due,'pending',nullif(trim(payment_note),''),auth.uid())
  returning id into purchase_id;

  for item in select * from jsonb_array_elements(items) loop
    select * into product from public.catalog_products where id=(item->>'product_id')::uuid and organization_id=target_org for update;
    if product.id is null then raise exception 'invalid_product'; end if;
    item_qty=(item->>'quantity')::numeric; item_cost=(item->>'unit_cost')::numeric;
    if item_qty<=0 or item_qty<>trunc(item_qty) or item_cost<0 then raise exception 'invalid_purchase_item'; end if;
    purchase_total:=purchase_total+round(item_qty*item_cost,2);
    new_average:=case when product.stock+item_qty>0 then round(((product.stock*product.average_cost)+(item_qty*item_cost))/(product.stock+item_qty),2) else item_cost end;
    insert into public.inventory_purchase_items(purchase_id,product_id,quantity,unit_cost,total) values(purchase_id,product.id,item_qty,item_cost,round(item_qty*item_cost,2));
    insert into public.inventory_movements(organization_id,product_id,movement_type,quantity,unit_cost,reference_type,reference_id,occurred_at,created_by)
    values(target_org,product.id,'purchase',item_qty,item_cost,'purchase',purchase_id,coalesce(purchase_on,current_date)::timestamptz,auth.uid());
    update public.catalog_products set stock=stock+item_qty::integer,average_cost=new_average,updated_at=now() where id=product.id;
  end loop;

  if pay_method='cash' then paid_value:=purchase_total; end if;
  if paid_value<0 or paid_value>purchase_total then raise exception 'invalid_initial_payment'; end if;
  if pay_method='credit' and paid_value<>0 then raise exception 'credit_initial_payment_must_be_zero'; end if;
  if pay_method='partial' and (paid_value<=0 or paid_value>=purchase_total) then raise exception 'partial_payment_out_of_range'; end if;
  update public.inventory_purchases set total=purchase_total,paid_amount=paid_value,
    payment_status=case when paid_value>=purchase_total then 'paid' when paid_value>0 then 'partial' else 'pending' end
  where id=purchase_id;
  if paid_value>0 then
    insert into public.supplier_payments(purchase_id,organization_id,amount,method,payment_date,reference,note,created_by)
    values(purchase_id,target_org,paid_value,'cash',coalesce(purchase_on,current_date),'Pago inicial',nullif(trim(payment_note),''),auth.uid());
  end if;
  return purchase_id;
end $$;

revoke all on function public.register_inventory_purchase_payable(uuid,date,uuid,text,text,text,numeric,date,text,jsonb) from public,anon;
grant execute on function public.register_inventory_purchase_payable(uuid,date,uuid,text,text,text,numeric,date,text,jsonb) to authenticated;

create or replace function public.register_supplier_payment(
  target_purchase uuid,
  payment_amount numeric,
  payment_method text,
  paid_on date,
  payment_reference text default null,
  payment_note text default null
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  purchase public.inventory_purchases%rowtype;
  payment_id uuid;
  next_paid numeric;
begin
  select * into purchase from public.inventory_purchases where id=target_purchase for update;
  if purchase.id is null then raise exception 'purchase_not_found'; end if;
  if auth.uid() is null or not (public.is_org_member(purchase.organization_id) or public.is_platform_admin()) then raise exception 'not_authorized'; end if;
  if purchase.payment_status in ('paid','cancelled') then raise exception 'purchase_not_payable'; end if;
  if payment_method not in ('cash','transfer','card','other') then raise exception 'invalid_payment_method'; end if;
  if payment_amount<=0 or payment_amount>(purchase.total-purchase.paid_amount) then raise exception 'invalid_payment_amount'; end if;
  insert into public.supplier_payments(purchase_id,organization_id,amount,method,payment_date,reference,note,created_by)
  values(purchase.id,purchase.organization_id,payment_amount,payment_method,coalesce(paid_on,current_date),nullif(trim(payment_reference),''),nullif(trim(payment_note),''),auth.uid()) returning id into payment_id;
  next_paid:=purchase.paid_amount+payment_amount;
  update public.inventory_purchases set paid_amount=next_paid,payment_status=case when next_paid>=total then 'paid' else 'partial' end where id=purchase.id;
  return payment_id;
end $$;

revoke all on function public.register_supplier_payment(uuid,numeric,text,date,text,text) from public,anon;
grant execute on function public.register_supplier_payment(uuid,numeric,text,date,text,text) to authenticated;

notify pgrst,'reload schema';
