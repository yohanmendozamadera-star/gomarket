insert into public.permissions(code, module, action, description)
values ('pos.sell', 'pos', 'sell', 'Registrar ventas desde la caja interna')
on conflict (code) do update
set module = excluded.module,
    action = excluded.action,
    description = excluded.description;

insert into public.role_permissions(role_id, permission_id)
select r.id, p.id
from public.roles r
cross join public.permissions p
where r.scope = 'organization'
  and r.code in ('owner','organization_admin','order_operator')
  and p.code = 'pos.sell'
on conflict do nothing;
