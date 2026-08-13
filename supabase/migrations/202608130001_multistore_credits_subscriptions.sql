-- Independent provider storefronts, credit sales and subscription history.
alter table public.organizations add column if not exists slug text;
create unique index if not exists organizations_slug_unique on public.organizations(lower(slug)) where slug is not null;

update public.organizations
set slug = trim(both '-' from regexp_replace(lower(unaccent(name)), '[^a-z0-9]+', '-', 'g')) || '-' || left(id::text, 6)
where slug is null;

create table if not exists public.credit_sales (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  order_id uuid references public.marketplace_orders(id) on delete set null,
  customer_name text not null,
  customer_phone text,
  total numeric(14,2) not null check (total > 0),
  paid_amount numeric(14,2) not null default 0 check (paid_amount >= 0),
  balance numeric(14,2) generated always as (greatest(total-paid_amount,0)) stored,
  status text not null default 'active' check (status in ('active','paid','cancelled')),
  due_date date,
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.credit_payments (
  id uuid primary key default gen_random_uuid(),
  credit_sale_id uuid not null references public.credit_sales(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  amount numeric(14,2) not null check (amount > 0),
  method text not null default 'cash',
  received_by uuid not null default auth.uid(),
  paid_at timestamptz not null default now()
);

create table if not exists public.subscription_payments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  amount numeric(14,2) not null check (amount > 0),
  status text not null default 'paid' check (status in ('pending','paid','failed','refunded')),
  method text not null default 'online',
  period_label text not null,
  paid_at timestamptz not null default now()
);

alter table public.credit_sales enable row level security;
alter table public.credit_payments enable row level security;
alter table public.subscription_payments enable row level security;

create policy "credit_sales_org" on public.credit_sales for all to authenticated using(public.is_org_member(organization_id)) with check(public.is_org_member(organization_id));
create policy "credit_payments_org" on public.credit_payments for select to authenticated using(public.is_org_member(organization_id));
create policy "subscription_payments_org" on public.subscription_payments for select to authenticated using(public.is_org_member(organization_id) or public.is_platform_admin());

create or replace function public.register_credit_payment(target_credit uuid, payment_amount numeric, payment_method text default 'cash')
returns uuid language plpgsql security definer set search_path=public as $$
declare sale public.credit_sales%rowtype; payment_id uuid;
begin
  select * into sale from public.credit_sales where id=target_credit for update;
  if sale.id is null or not public.is_org_member(sale.organization_id) then raise exception 'credit_not_available'; end if;
  if payment_amount <= 0 or payment_amount > sale.balance then raise exception 'invalid_payment_amount'; end if;
  insert into public.credit_payments(credit_sale_id,organization_id,amount,method) values(sale.id,sale.organization_id,payment_amount,payment_method) returning id into payment_id;
  update public.credit_sales set paid_amount=paid_amount+payment_amount,status=case when paid_amount+payment_amount>=total then 'paid' else 'active' end,updated_at=now() where id=sale.id;
  return payment_id;
end $$;

grant select,insert,update on public.credit_sales to authenticated;
grant select on public.credit_payments,public.subscription_payments to authenticated;
grant execute on function public.register_credit_payment(uuid,numeric,text) to authenticated;
