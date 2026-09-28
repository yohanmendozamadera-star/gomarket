update public.catalog_products
set sku = 'GM-' || upper(substr(replace(id::text, '-', ''), 1, 10))
where sku is null or btrim(sku) = '';

alter table public.catalog_products
  alter column sku set not null;

create or replace function public.save_catalog_product(payload jsonb)
returns public.catalog_products
language plpgsql
security definer
set search_path = public
as $$
declare
  result public.catalog_products;
  product_org uuid := (payload->>'organization_id')::uuid;
  generated_sku text;
begin
  if auth.uid() is null then raise exception 'authentication_required'; end if;
  if not (is_org_manager(product_org) or is_org_owner(product_org)) then raise exception 'not_authorized'; end if;

  loop
    generated_sku := 'GM-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));
    exit when not exists (
      select 1 from public.catalog_products
      where organization_id = product_org and sku = generated_sku
    );
  end loop;

  insert into catalog_products(organization_id,name,category,description,price,stock,image_url,unit_measure,unit_quantity,sku,is_active)
  values(product_org,payload->>'name',payload->>'category',payload->>'description',(payload->>'price')::numeric,(payload->>'stock')::int,nullif(payload->>'image_url',''),coalesce(payload->>'unit_measure','unidad'),coalesce((payload->>'unit_quantity')::numeric,1),generated_sku,true)
  returning * into result;
  return result;
end;
$$;

create or replace function public.update_catalog_product(target_product uuid,payload jsonb)
returns public.catalog_products
language plpgsql
security definer
set search_path = public
as $$
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
    unit_quantity=coalesce((payload->>'unit_quantity')::numeric,1)
  where id=target_product
  returning * into result;
  return result;
end;
$$;

revoke execute on function public.save_catalog_product(jsonb) from public;
revoke execute on function public.update_catalog_product(uuid,jsonb) from public;
revoke execute on function public.save_catalog_product(jsonb) from anon;
revoke execute on function public.update_catalog_product(uuid,jsonb) from anon;
grant execute on function public.save_catalog_product(jsonb) to authenticated;
grant execute on function public.update_catalog_product(uuid,jsonb) to authenticated;
notify pgrst, 'reload schema';
