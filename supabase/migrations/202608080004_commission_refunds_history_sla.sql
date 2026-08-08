alter table public.marketplace_orders
  add column if not exists delivered_at timestamptz,
  add column if not exists cancelled_at timestamptz,
  add column if not exists commission_refund_due_at timestamptz,
  add column if not exists commission_refunded_at timestamptz;

update public.marketplace_orders o
set delivered_at=coalesce(o.delivered_at,(select min(h.created_at) from public.order_status_history h where h.order_id=o.id and h.status='delivered'),o.updated_at)
where o.status='delivered' and o.delivered_at is null;

update public.marketplace_orders o
set cancelled_at=coalesce(o.cancelled_at,(select min(h.created_at) from public.order_status_history h where h.order_id=o.id and h.status='cancelled'),o.updated_at),
    commission_refund_due_at=case when o.customer_data_unlocked then coalesce(o.commission_refund_due_at,(select min(h.created_at)+interval '24 hours' from public.order_status_history h where h.order_id=o.id and h.status='cancelled'),o.updated_at+interval '24 hours') else null end
where o.status='cancelled' and o.cancelled_at is null;

create unique index if not exists wallet_one_refund_per_order_idx
on public.wallet_transactions(order_id,kind) where kind='refund';

create or replace function public.process_due_commission_refunds()
returns integer language plpgsql security definer set search_path=public as $$
declare ord marketplace_orders%rowtype; bal numeric; processed integer:=0;
begin
  for ord in
    select * from marketplace_orders
    where status='cancelled' and customer_data_unlocked
      and commission_refund_due_at<=now() and commission_refunded_at is null
    order by commission_refund_due_at for update skip locked
  loop
    insert into wallet_accounts(organization_id,balance) values(ord.organization_id,0) on conflict do nothing;
    update wallet_accounts set balance=balance+ord.commission_amount,updated_at=now()
      where organization_id=ord.organization_id returning balance into bal;
    insert into wallet_transactions(organization_id,order_id,kind,amount,balance_after,description)
      values(ord.organization_id,ord.id,'refund',ord.commission_amount,bal,'Devolución de comisión por pedido cancelado')
      on conflict do nothing;
    update marketplace_orders set commission_refunded_at=now(),updated_at=now() where id=ord.id;
    processed:=processed+1;
  end loop;
  return processed;
end $$;

create or replace function public.set_provider_order_status(target_order uuid,next_status text,status_note text default null,new_delivery_lat double precision default null,new_delivery_lng double precision default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare ord marketplace_orders%rowtype; allowed boolean:=false;
begin
  select * into ord from marketplace_orders where id=target_order for update;
  if ord.id is null or not is_org_manager(ord.organization_id) then raise exception 'not_authorized'; end if;
  allowed:=case
    when ord.status in ('pending_confirmation','returned') then next_status in ('orders','cancelled')
    when ord.status in ('orders','confirmed') then next_status in ('preparing','cancelled')
    when ord.status='preparing' then next_status in ('dispatched','cancelled')
    when ord.status='dispatched' then next_status='out_for_delivery'
    when ord.status='out_for_delivery' then next_status='delivered'
    else false end;
  if not allowed then raise exception 'invalid_transition_%_to_%',ord.status,next_status; end if;
  update marketplace_orders set status=next_status,updated_at=now(),
    return_reason=case when next_status='cancelled' then status_note else return_reason end,
    delivered_lat=case when next_status='delivered' then new_delivery_lat else delivered_lat end,
    delivered_lng=case when next_status='delivered' then new_delivery_lng else delivered_lng end,
    delivered_at=case when next_status='delivered' then now() else delivered_at end,
    cancelled_at=case when next_status='cancelled' then now() else cancelled_at end,
    commission_refund_due_at=case when next_status='cancelled' and ord.customer_data_unlocked then now()+interval '24 hours' else commission_refund_due_at end
  where id=target_order;
  insert into order_status_history(order_id,status,actor_user_id,note)
  values(target_order,next_status,auth.uid(),case when ord.status='returned' and next_status='orders' then 'Pedido devuelto confirmado nuevamente' else status_note end);
  return jsonb_build_object('status',next_status,'updated',true,'refund_due_at',case when next_status='cancelled' and ord.customer_data_unlocked then now()+interval '24 hours' else null end);
end $$;

drop function if exists public.get_provider_orders(uuid);
create function public.get_provider_orders(target_org uuid)
returns table(id uuid,order_number bigint,status text,payment_method text,payment_status text,total numeric,commission_amount numeric,customer_data_unlocked boolean,customer_name text,customer_phone text,delivery_address text,delivery_city text,created_at timestamptz,updated_at timestamptz,delivered_at timestamptz,cancelled_at timestamptz,commission_refund_due_at timestamptz,commission_refunded_at timestamptz)
language plpgsql security definer set search_path=public as $$
begin
 if not is_org_member(target_org) then raise exception 'not_authorized'; end if;
 perform process_due_commission_refunds();
 return query select o.id,o.order_number,o.status,o.payment_method,o.payment_status,o.total,o.commission_amount,o.customer_data_unlocked,
  case when o.customer_data_unlocked then o.customer_name else 'Datos protegidos' end,
  case when o.customer_data_unlocked then o.customer_phone else null end,
  case when o.customer_data_unlocked then o.delivery_address else 'Datos protegidos' end,
  case when o.customer_data_unlocked then o.delivery_city else 'Protegida' end,
  o.created_at,o.updated_at,o.delivered_at,o.cancelled_at,o.commission_refund_due_at,o.commission_refunded_at
 from marketplace_orders o where o.organization_id=target_org order by o.created_at desc;
end $$;

drop function if exists public.get_admin_marketplace_overview();
create function public.get_admin_marketplace_overview()
returns table(id uuid,order_number bigint,organization_name text,status text,payment_method text,total numeric,commission_amount numeric,customer_name text,created_at timestamptz,updated_at timestamptz,delivered_at timestamptz,cancelled_at timestamptz,commission_refund_due_at timestamptz,commission_refunded_at timestamptz,customer_data_unlocked boolean)
language plpgsql security definer set search_path=public as $$
begin
 if not is_platform_admin() then raise exception 'not_authorized'; end if;
 perform process_due_commission_refunds();
 return query select o.id,o.order_number,g.name,o.status,o.payment_method,o.total,o.commission_amount,o.customer_name,o.created_at,o.updated_at,o.delivered_at,o.cancelled_at,o.commission_refund_due_at,o.commission_refunded_at,o.customer_data_unlocked
 from marketplace_orders o join organizations g on g.id=o.organization_id order by o.created_at desc;
end $$;

grant execute on function public.process_due_commission_refunds() to authenticated;
grant execute on function public.set_provider_order_status(uuid,text,text,double precision,double precision) to authenticated;
grant execute on function public.get_provider_orders(uuid) to authenticated;
grant execute on function public.get_admin_marketplace_overview() to authenticated;

do $$ begin
  create extension if not exists pg_cron with schema extensions;
exception when others then raise notice 'pg_cron no disponible; las devoluciones se procesarán al abrir el panel'; end $$;

do $$ begin
  if exists(select 1 from pg_namespace where nspname='cron') and not exists(select 1 from cron.job where jobname='gomarket-commission-refunds') then
    perform cron.schedule('gomarket-commission-refunds','*/10 * * * *','select public.process_due_commission_refunds()');
  end if;
exception when others then raise notice 'No se pudo programar cron; se procesará al abrir el panel'; end $$;

notify pgrst,'reload schema';
