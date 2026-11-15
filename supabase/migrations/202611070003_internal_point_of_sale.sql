alter table public.catalog_products
  alter column stock type numeric(14,3) using stock::numeric;

alter table public.marketplace_orders
  add column if not exists is_internal_sale boolean not null default false;

create or replace function public.register_internal_sale(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  target_org uuid := (payload->>'organization_id')::uuid;
  pay_method text := payload->>'payment_method';
  customer text := coalesce(nullif(trim(payload->>'customer_name'), ''), 'Consumidor final');
  sale_total numeric := 0;
  cash_value numeric := 0;
  card_value numeric := 0;
  credit_value numeric := 0;
  initial_payment numeric := 0;
  sale_id uuid;
  sale_number bigint;
  item jsonb;
  product public.catalog_products%rowtype;
  item_quantity numeric;
  item_price numeric;
  is_owner boolean;
  is_admin boolean;
  is_member boolean;
begin
  if auth.uid() is null then
    raise exception 'authentication_required';
  end if;

  select exists(
    select 1 from public.organization_members m
    where m.organization_id = target_org and m.user_id = auth.uid() and m.status = 'active'
  ) into is_member;
  select exists(
    select 1 from public.organizations o
    where o.id = target_org and o.owner_user_id = auth.uid() and o.status = 'active'
  ) into is_owner;
  select exists(
    select 1 from public.profiles p
    where p.id = auth.uid() and p.platform_role = 'super_admin' and p.status = 'active'
  ) into is_admin;

  if not (is_member or is_owner or is_admin) then
    raise exception 'internal_sale_not_authorized';
  end if;
  if pay_method not in ('cash_on_delivery','card','credit','shared') then
    raise exception 'invalid_payment_method';
  end if;
  if jsonb_array_length(coalesce(payload->'items','[]'::jsonb)) = 0 then
    raise exception 'sale_without_items';
  end if;

  for item in select * from jsonb_array_elements(payload->'items') loop
    select * into product
    from public.catalog_products
    where id = (item->>'product_id')::uuid and organization_id = target_org and is_active
    for update;
    if not found then raise exception 'product_not_available'; end if;

    item_quantity := (item->>'quantity')::numeric;
    item_price := (item->>'unit_price')::numeric;
    if item_quantity <= 0 or item_quantity > product.stock then raise exception 'insufficient_stock_for_%', product.name; end if;
    if item_price < 0 then raise exception 'invalid_sale_price'; end if;
    if abs(item_price - product.price) > 0.001 and not (is_owner or is_admin) then
      raise exception 'price_override_requires_owner';
    end if;
    sale_total := sale_total + (item_quantity * item_price);
  end loop;

  if pay_method = 'shared' then
    cash_value := greatest(0, coalesce((payload->>'shared_cash_amount')::numeric, 0));
    card_value := greatest(0, coalesce((payload->>'shared_card_amount')::numeric, 0));
    credit_value := greatest(0, coalesce((payload->>'shared_credit_amount')::numeric, 0));
    if abs((cash_value + card_value + credit_value) - sale_total) > 0.01 then
      raise exception 'shared_payment_must_match_total';
    end if;
  elsif pay_method = 'cash_on_delivery' then
    cash_value := sale_total;
  elsif pay_method = 'card' then
    card_value := sale_total;
  else
    credit_value := sale_total;
  end if;
  initial_payment := cash_value + card_value;

  insert into public.marketplace_orders(
    organization_id, customer_user_id, customer_name, customer_phone,
    delivery_address, delivery_city, payment_method, payment_status, status,
    subtotal, delivery_fee, total, commission_amount, customer_data_unlocked,
    shared_cash_amount, shared_card_amount, shared_credit_amount,
    delivered_at, is_internal_sale, notes
  ) values (
    target_org, auth.uid(), customer, '', '', 'Venta interna', pay_method,
    case when credit_value > 0 then 'credit' else 'paid' end,
    'delivered', sale_total, 0, sale_total, 0, true,
    cash_value, card_value, credit_value, now(), true, 'Venta registrada desde caja interna'
  ) returning id, order_number into sale_id, sale_number;

  for item in select * from jsonb_array_elements(payload->'items') loop
    select * into product from public.catalog_products
    where id = (item->>'product_id')::uuid and organization_id = target_org
    for update;
    item_quantity := (item->>'quantity')::numeric;
    item_price := (item->>'unit_price')::numeric;

    insert into public.marketplace_order_items(
      order_id, product_id, product_name, quantity, unit_price, total,
      unit_measure, unit_quantity, unit_cost
    ) values (
      sale_id, product.id, product.name, item_quantity, item_price,
      item_quantity * item_price, product.unit_measure, product.unit_quantity,
      coalesce(product.average_cost, 0)
    );

    update public.catalog_products
    set stock = stock - item_quantity, updated_at = now()
    where id = product.id;

    insert into public.inventory_movements(
      organization_id, product_id, movement_type, quantity, unit_cost,
      reference_type, reference_id, note, created_by
    ) values (
      target_org, product.id, 'sale', -item_quantity, coalesce(product.average_cost, 0),
      'internal_sale', sale_id, format('Venta interna #%s', sale_number), auth.uid()
    );
  end loop;

  if credit_value > 0 then
    insert into public.credit_sales(
      organization_id, order_id, customer_name, total, paid_amount, status, created_by
    ) values (
      target_org, sale_id, customer, sale_total, initial_payment, 'active', auth.uid()
    );
  end if;

  insert into public.order_status_history(order_id, status, actor_user_id, note)
  values(sale_id, 'delivered', auth.uid(), 'Venta interna finalizada en caja');

  return jsonb_build_object(
    'id', sale_id, 'order_number', sale_number, 'total', sale_total,
    'payment_method', pay_method, 'cash_amount', cash_value,
    'card_amount', card_value, 'credit_amount', credit_value
  );
end
$$;

revoke execute on function public.register_internal_sale(jsonb) from public, anon;
grant execute on function public.register_internal_sale(jsonb) to authenticated;
notify pgrst, 'reload schema';
