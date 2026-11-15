create table if not exists public.business_customers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null,
  phone text not null,
  purchase_count integer not null default 0 check (purchase_count >= 0),
  total_purchases numeric(14,2) not null default 0 check (total_purchases >= 0),
  first_purchase_at timestamptz not null default now(),
  last_purchase_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(organization_id, phone)
);

alter table public.business_customers enable row level security;
drop policy if exists business_customers_read on public.business_customers;
create policy business_customers_read on public.business_customers
for select to authenticated
using (public.is_org_member(organization_id) or public.is_super_admin());

grant select on public.business_customers to authenticated;

do $$
begin
  if to_regprocedure('public.register_internal_sale_core(jsonb)') is null then
    alter function public.register_internal_sale(jsonb) rename to register_internal_sale_core;
  end if;
end
$$;
revoke execute on function public.register_internal_sale_core(jsonb) from public, anon, authenticated;

create or replace function public.register_internal_sale(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  result jsonb;
  sale_id uuid;
  sale_total numeric;
  org_id uuid := (payload->>'organization_id')::uuid;
  v_customer_name text := trim(coalesce(payload->>'customer_name',''));
  v_customer_phone text := regexp_replace(coalesce(payload->>'customer_phone',''), '\D', '', 'g');
  pay_method text := payload->>'payment_method';
  credit_requested boolean;
begin
  credit_requested := pay_method = 'credit'
    or (pay_method = 'shared' and greatest(0, coalesce((payload->>'shared_credit_amount')::numeric,0)) > 0);

  if credit_requested and (
    v_customer_name = ''
    or lower(v_customer_name) = 'consumidor final'
    or length(v_customer_phone) <> 10
  ) then
    raise exception 'credit_customer_identity_required';
  end if;

  result := public.register_internal_sale_core(payload);
  sale_id := (result->>'id')::uuid;
  sale_total := (result->>'total')::numeric;

  update public.marketplace_orders
  set customer_phone = v_customer_phone
  where id = sale_id;

  if v_customer_phone <> '' then
    insert into public.business_customers(
      organization_id, name, phone, purchase_count, total_purchases,
      first_purchase_at, last_purchase_at, updated_at
    ) values (
      org_id, v_customer_name, v_customer_phone, 1, sale_total, now(), now(), now()
    )
    on conflict (organization_id, phone) do update
    set name = excluded.name,
        purchase_count = public.business_customers.purchase_count + 1,
        total_purchases = public.business_customers.total_purchases + excluded.total_purchases,
        last_purchase_at = now(),
        updated_at = now();
  end if;

  update public.credit_sales
  set customer_phone = nullif(v_customer_phone, ''),
      customer_name = v_customer_name,
      updated_at = now()
  where order_id = sale_id;

  return result;
end
$$;

revoke execute on function public.register_internal_sale(jsonb) from public, anon;
grant execute on function public.register_internal_sale(jsonb) to authenticated;
notify pgrst, 'reload schema';
