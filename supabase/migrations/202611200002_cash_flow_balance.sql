create or replace function public.get_provider_cash_flow_balance(target_org uuid,date_from date,date_to date)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare result jsonb;
begin
  if auth.uid() is null or not (public.is_org_member(target_org) or public.is_platform_admin()) then raise exception 'not_authorized'; end if;
  if date_to<date_from then raise exception 'invalid_date_range'; end if;

  with period_orders as (
    select * from public.marketplace_orders
    where organization_id=target_org
      and (created_at at time zone 'America/Bogota')::date between date_from and date_to
      and status not in ('cancelled','returned')
  ), period_sales as (
    select
      coalesce(sum(case when payment_method='cash_on_delivery' and status='delivered' then total when payment_method='shared' then shared_cash_amount else 0 end),0) cash_sales,
      coalesce(sum(case when payment_method='card' then total when payment_method='shared' then shared_card_amount else 0 end),0) transfer_sales
    from period_orders
  ), period_receipts as (
    select coalesce(sum(amount),0) credit_receipts from public.credit_payments
    where organization_id=target_org and (paid_at at time zone 'America/Bogota')::date between date_from and date_to
  ), period_supplier_payments as (
    select coalesce(sum(amount),0) supplier_outflow from public.supplier_payments
    where organization_id=target_org and payment_date between date_from and date_to
  ), period_expenses as (
    select coalesce(sum(amount),0) expense_outflow from public.business_expenses
    where organization_id=target_org and expense_date between date_from and date_to
  ), all_sales_to_date as (
    select coalesce(sum(case when payment_method='cash_on_delivery' and status='delivered' then total when payment_method='card' then total when payment_method='shared' then coalesce(shared_cash_amount,0)+coalesce(shared_card_amount,0) else 0 end),0) collected_sales
    from public.marketplace_orders
    where organization_id=target_org and (created_at at time zone 'America/Bogota')::date<=date_to and status not in ('cancelled','returned')
  ), all_receipts_to_date as (
    select coalesce(sum(amount),0) credit_receipts from public.credit_payments
    where organization_id=target_org and (paid_at at time zone 'America/Bogota')::date<=date_to
  ), all_supplier_payments_to_date as (
    select coalesce(sum(amount),0) supplier_outflow from public.supplier_payments
    where organization_id=target_org and payment_date<=date_to
  ), all_expenses_to_date as (
    select coalesce(sum(amount),0) expense_outflow from public.business_expenses
    where organization_id=target_org and expense_date<=date_to
  ), receivables as (
    select coalesce(sum(greatest(c.balance+coalesce(later.amount,0),0)),0) value
    from public.credit_sales c
    left join lateral (
      select sum(p.amount) amount from public.credit_payments p
      where p.credit_sale_id=c.id and (p.paid_at at time zone 'America/Bogota')::date>date_to
    ) later on true
    where c.organization_id=target_org and (c.created_at at time zone 'America/Bogota')::date<=date_to and c.status<>'cancelled'
  ), payables as (
    select coalesce(sum(greatest(p.total-coalesce(x.paid,0),0)),0) value
    from public.inventory_purchases p
    left join lateral (
      select sum(sp.amount) paid from public.supplier_payments sp where sp.purchase_id=p.id and sp.payment_date<=date_to
    ) x on true
    where p.organization_id=target_org and p.purchase_date<=date_to and p.payment_status<>'cancelled'
  ), inventory as (
    select coalesce(sum(stock*average_cost),0) value from public.catalog_products where organization_id=target_org
  )
  select jsonb_build_object(
    'cash_sales',period_sales.cash_sales,
    'transfer_sales',period_sales.transfer_sales,
    'credit_receipts',period_receipts.credit_receipts,
    'cash_inflow',period_sales.cash_sales+period_sales.transfer_sales+period_receipts.credit_receipts,
    'supplier_outflow',period_supplier_payments.supplier_outflow,
    'expense_outflow',period_expenses.expense_outflow,
    'cash_outflow',period_supplier_payments.supplier_outflow+period_expenses.expense_outflow,
    'net_cash_flow',period_sales.cash_sales+period_sales.transfer_sales+period_receipts.credit_receipts-period_supplier_payments.supplier_outflow-period_expenses.expense_outflow,
    'accounts_receivable',receivables.value,
    'expected_cash',all_sales_to_date.collected_sales+all_receipts_to_date.credit_receipts-all_supplier_payments_to_date.supplier_outflow-all_expenses_to_date.expense_outflow,
    'inventory_value',inventory.value,
    'accounts_payable',payables.value,
    'net_position',all_sales_to_date.collected_sales+all_receipts_to_date.credit_receipts-all_supplier_payments_to_date.supplier_outflow-all_expenses_to_date.expense_outflow+receivables.value+inventory.value-payables.value
  ) into result
  from period_sales,period_receipts,period_supplier_payments,period_expenses,all_sales_to_date,all_receipts_to_date,all_supplier_payments_to_date,all_expenses_to_date,receivables,payables,inventory;
  return result;
end $$;

revoke all on function public.get_provider_cash_flow_balance(uuid,date,date) from public,anon;
grant execute on function public.get_provider_cash_flow_balance(uuid,date,date) to authenticated;

notify pgrst,'reload schema';
