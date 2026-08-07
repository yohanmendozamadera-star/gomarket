create or replace function public.update_catalog_product(target_product uuid,payload jsonb)
returns public.catalog_products language plpgsql security definer set search_path=public as $$
declare
  product_org uuid;
  result public.catalog_products;
begin
  if auth.uid() is null then raise exception 'authentication_required'; end if;
  select organization_id into product_org from public.catalog_products where id=target_product;
  if product_org is null then raise exception 'product_not_found'; end if;
  if not (public.is_org_manager(product_org) or public.is_org_owner(product_org)) then raise exception 'not_authorized'; end if;

  update public.catalog_products set
    name=payload->>'name',
    category=payload->>'category',
    description=coalesce(payload->>'description',''),
    price=(payload->>'price')::numeric,
    stock=(payload->>'stock')::int,
    image_url=case when payload ? 'image_url' then nullif(payload->>'image_url','') else image_url end,
    unit_measure=coalesce(payload->>'unit_measure','unidad'),
    unit_quantity=coalesce((payload->>'unit_quantity')::numeric,1),
    sku=nullif(payload->>'sku','')
  where id=target_product
  returning * into result;
  return result;
end $$;

grant execute on function public.update_catalog_product(uuid,jsonb) to authenticated;
notify pgrst,'reload schema';
