-- TopSafeB: secure customer-to-owner simulated transfer.
-- Run this migration in Supabase SQL Editor after demo-funds-setup.sql.
-- The function moves fictional USD balances only; it does not connect to payment rails.

create or replace function public.customer_demo_transfer_to_owner(
  p_amount numeric,
  p_description text default ''
)
returns table(customer_balance numeric, owner_balance numeric, transaction_id uuid)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer_id uuid := auth.uid();
  v_owner_id uuid;
  v_admin_count integer;
  v_amount numeric(14,2);
  v_customer_balance numeric(14,2);
  v_owner_balance numeric(14,2);
  v_customer_new numeric(14,2);
  v_owner_new numeric(14,2);
  v_transaction_id uuid;
  v_description text := left(coalesce(trim(p_description), ''), 200);
begin
  if v_customer_id is null then
    raise exception 'Please sign in before transferring demo funds';
  end if;

  if coalesce((
    select c.is_blocked
    from public.customer_access_controls c
    where c.user_id = v_customer_id
  ), false) then
    raise exception 'Transfers are temporarily restricted by the TopSafeB owner. Please contact support.';
  end if;

  if p_amount is null or p_amount <= 0 or p_amount > 1000000000 then
    raise exception 'Enter an amount greater than zero and no more than 1,000,000,000';
  end if;
  v_amount := round(p_amount, 2);
  if v_amount <= 0 then
    raise exception 'The transfer amount must be at least 0.01 USD';
  end if;

  select count(*) into v_admin_count from public.admin_users;
  if v_admin_count = 0 then
    raise exception 'The TopSafeB owner account is not configured';
  elsif v_admin_count > 1 then
    raise exception 'More than one administrator is configured. Ask the owner to confirm the receiving account before transferring.';
  end if;

  select user_id into v_owner_id from public.admin_users limit 1;
  if v_owner_id is null or v_owner_id = v_customer_id then
    raise exception 'A separate TopSafeB owner account could not be identified';
  end if;

  insert into public.demo_accounts(user_id, balance)
  values (v_customer_id, 0), (v_owner_id, 0)
  on conflict (user_id) do nothing;

  -- Lock both ledgers in a consistent order to prevent concurrent transfer races.
  perform user_id
  from public.demo_accounts
  where user_id in (v_customer_id, v_owner_id)
  order by user_id
  for update;

  select balance into v_customer_balance
  from public.demo_accounts where user_id = v_customer_id;
  select balance into v_owner_balance
  from public.demo_accounts where user_id = v_owner_id;

  if v_customer_balance < v_amount then
    raise exception 'Insufficient demo funds. Available balance: % USD', v_customer_balance;
  end if;

  v_customer_new := v_customer_balance - v_amount;
  v_owner_new := v_owner_balance + v_amount;

  update public.demo_accounts
  set balance = v_customer_new, updated_at = now()
  where user_id = v_customer_id;

  update public.demo_accounts
  set balance = v_owner_new, updated_at = now()
  where user_id = v_owner_id;

  insert into public.demo_transactions(user_id, action, amount, balance_after, note, created_by)
  values (
    v_customer_id, 'transfer', v_amount, v_customer_new,
    'Demo transfer sent to TopSafeB owner' ||
      case when v_description <> '' then ' | Description: ' || v_description else '' end,
    v_customer_id
  )
  returning id into v_transaction_id;

  insert into public.demo_transactions(user_id, action, amount, balance_after, note, created_by)
  values (
    v_owner_id, 'transfer', v_amount, v_owner_new,
    'Demo transfer received from customer ' || v_customer_id::text ||
      case when v_description <> '' then ' | Description: ' || v_description else '' end,
    v_customer_id
  );

  return query select v_customer_new, v_owner_new, v_transaction_id;
end;
$$;

revoke all on function public.customer_demo_transfer_to_owner(numeric, text) from public;
grant execute on function public.customer_demo_transfer_to_owner(numeric, text) to authenticated;
