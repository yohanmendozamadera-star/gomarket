alter table public.catalog_products add column if not exists unit_measure text not null default 'unidad' check(unit_measure in ('unidad','libra','gramo','kilogramo'));
alter table public.catalog_products add column if not exists unit_quantity numeric(12,3) not null default 1 check(unit_quantity>0);
alter table public.catalog_products add column if not exists sku text;
create unique index if not exists catalog_products_org_sku_idx on public.catalog_products(organization_id,sku) where sku is not null;

create or replace function public.save_catalog_product(payload jsonb)
returns public.catalog_products language plpgsql security definer set search_path=public as $$
declare result public.catalog_products;
begin
 if auth.uid() is null then raise exception 'authentication_required'; end if;
 if not (is_org_manager((payload->>'organization_id')::uuid) or is_org_owner((payload->>'organization_id')::uuid)) then raise exception 'not_authorized'; end if;
 insert into catalog_products(organization_id,name,category,description,price,stock,image_url,unit_measure,unit_quantity,sku,is_active)
 values((payload->>'organization_id')::uuid,payload->>'name',payload->>'category',payload->>'description',(payload->>'price')::numeric,(payload->>'stock')::int,nullif(payload->>'image_url',''),coalesce(payload->>'unit_measure','unidad'),coalesce((payload->>'unit_quantity')::numeric,1),nullif(payload->>'sku',''),true)
 returning * into result;
 return result;
end $$;
grant execute on function public.save_catalog_product(jsonb) to authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('product-images','product-images',true,5242880,array['image/jpeg','image/png','image/webp'])
on conflict(id) do update set public=true,file_size_limit=5242880,allowed_mime_types=array['image/jpeg','image/png','image/webp'];

create policy "product_images_public_read" on storage.objects for select to public using(bucket_id='product-images');
create policy "product_images_provider_insert" on storage.objects for insert to authenticated with check(
 bucket_id='product-images' and (public.is_org_manager(((storage.foldername(name))[1])::uuid) or public.is_org_owner(((storage.foldername(name))[1])::uuid))
);
create policy "product_images_provider_update" on storage.objects for update to authenticated using(
 bucket_id='product-images' and (public.is_org_manager(((storage.foldername(name))[1])::uuid) or public.is_org_owner(((storage.foldername(name))[1])::uuid))
);
notify pgrst,'reload schema';
