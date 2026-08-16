alter table public.marketplace_orders drop constraint if exists marketplace_orders_payment_status_check;
alter table public.marketplace_orders add constraint marketplace_orders_payment_status_check
  check(payment_status in ('pending','paid','failed','cash_on_delivery','credit'));

create or replace function public.get_provider_order_detail(target_order uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare ord marketplace_orders%rowtype; result jsonb;
begin
  select * into ord from marketplace_orders where id=target_order;
  if ord.id is null or not (public.is_org_member(ord.organization_id) or public.is_platform_admin()) then
    raise exception 'not_authorized';
  end if;
  select jsonb_build_object(
    'id',ord.id,'order_number',ord.order_number,'customer_name',ord.customer_name,'customer_phone',ord.customer_phone,
    'delivery_address',ord.delivery_address,'delivery_city',ord.delivery_city,'notes',ord.notes,
    'payment_method',ord.payment_method,'status',ord.status,'subtotal',ord.subtotal,
    'discount_percent',ord.discount_percent,'discount_amount',ord.discount_amount,
    'delivery_fee',ord.delivery_fee,'total',ord.total,
    'return_reason',ord.return_reason,'return_notes',ord.return_notes,'return_photo_path',ord.return_photo_path,
    'items',coalesce((select jsonb_agg(jsonb_build_object(
      'product_name',i.product_name,'quantity',i.quantity,'unit_price',i.unit_price,'total',i.total,
      'unit_measure',i.unit_measure,'unit_quantity',i.unit_quantity
    ) order by i.product_name) from marketplace_order_items i where i.order_id=ord.id),'[]'::jsonb)
  ) into result;
  return result;
end $$;

grant execute on function public.get_provider_order_detail(uuid) to authenticated;
notify pgrst,'reload schema';
