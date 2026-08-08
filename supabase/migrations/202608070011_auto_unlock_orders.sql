create or replace function public.auto_unlock_provider_orders(target_org uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare ord marketplace_orders%rowtype; bal numeric; unlocked_count integer:=0;
begin
  if not is_org_manager(target_org) then raise exception 'not_authorized'; end if;
  select balance into bal from wallet_accounts where organization_id=target_org for update;
  bal:=coalesce(bal,0);
  for ord in
    select * from marketplace_orders
    where organization_id=target_org and customer_data_unlocked=false
    order by created_at for update
  loop
    exit when bal<ord.commission_amount;
    bal:=bal-ord.commission_amount;
    update wallet_accounts set balance=bal,updated_at=now() where organization_id=target_org;
    insert into wallet_transactions(organization_id,order_id,kind,amount,balance_after,description)
      values(target_org,ord.id,'commission',-ord.commission_amount,bal,'Comisión GoMarket 9,5% · desbloqueo automático');
    update marketplace_orders set customer_data_unlocked=true,updated_at=now() where id=ord.id;
    unlocked_count:=unlocked_count+1;
  end loop;
  return jsonb_build_object('unlocked_count',unlocked_count,'balance',bal);
end $$;

grant execute on function public.auto_unlock_provider_orders(uuid) to authenticated;
notify pgrst,'reload schema';
