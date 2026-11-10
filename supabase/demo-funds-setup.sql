-- TopSafeB simulated funds only. Run this entire file in Supabase SQL Editor.
-- This creates fictional USD balances. It does not connect to banking or payment rails.

create table if not exists public.demo_accounts (
  user_id uuid primary key references auth.users(id) on delete cascade,
  balance numeric(14,2) not null default 0 check (balance >= 0),
  currency text not null default 'USD' check (currency = 'USD'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.demo_transactions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  action text not null check (action in ('add','deduct','set')),
  amount numeric(14,2) not null check (amount > 0),
  balance_after numeric(14,2) not null check (balance_after >= 0),
  note text not null default '',
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);

create index if not exists demo_transactions_user_created_idx
  on public.demo_transactions(user_id, created_at desc);

alter table public.demo_accounts enable row level security;
alter table public.demo_transactions enable row level security;

drop policy if exists "Customers and admins can view demo accounts" on public.demo_accounts;
create policy "Customers and admins can view demo accounts"
on public.demo_accounts for select to authenticated
using (
  auth.uid() = user_id
  or exists (select 1 from public.admin_users a where a.user_id = auth.uid())
);

drop policy if exists "Customers and admins can view demo transactions" on public.demo_transactions;
create policy "Customers and admins can view demo transactions"
on public.demo_transactions for select to authenticated
using (
  auth.uid() = user_id
  or exists (select 1 from public.admin_users a where a.user_id = auth.uid())
);

create or replace function public.admin_adjust_demo_balance(
  p_user_id uuid,
  p_action text,
  p_amount numeric,
  p_note text default ''
)
returns table(new_balance numeric, transaction_id uuid)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_balance numeric(14,2);
  v_new_balance numeric(14,2);
  v_transaction_id uuid;
begin
  if auth.uid() is null or not exists (
    select 1 from public.admin_users where user_id = auth.uid()
  ) then
    raise exception 'Administrator access required';
  end if;

  if p_action not in ('add','deduct','set') then
    raise exception 'Choose add, deduct, or set';
  end if;
  if p_amount is null or p_amount <= 0 or p_amount > 1000000000 then
    raise exception 'Amount must be greater than zero and no more than 1,000,000,000';
  end if;
  if not exists (select 1 from auth.users where id = p_user_id) then
    raise exception 'Customer account not found';
  end if;

  insert into public.demo_accounts(user_id, balance)
  values (p_user_id, 0)
  on conflict (user_id) do nothing;

  select balance into v_balance
  from public.demo_accounts
  where user_id = p_user_id
  for update;

  if p_action = 'add' then
    v_new_balance := v_balance + p_amount;
  elsif p_action = 'deduct' then
    v_new_balance := v_balance - p_amount;
  else
    v_new_balance := p_amount;
  end if;

  if v_new_balance < 0 then
    raise exception 'This deduction is greater than the available demo balance';
  end if;

  update public.demo_accounts
  set balance = v_new_balance, updated_at = now()
  where user_id = p_user_id;

  insert into public.demo_transactions(user_id, action, amount, balance_after, note, created_by)
  values (p_user_id, p_action, p_amount, v_new_balance, left(coalesce(p_note,''),500), auth.uid())
  returning id into v_transaction_id;

  return query select v_new_balance, v_transaction_id;
end;
$$;

revoke all on function public.admin_adjust_demo_balance(uuid,text,numeric,text) from public;
grant execute on function public.admin_adjust_demo_balance(uuid,text,numeric,text) to authenticated;

-- Create zero-balance demo accounts for customers who already exist.
insert into public.demo_accounts(user_id)
select id from auth.users
on conflict (user_id) do nothing;

-- Automatically create a zero-balance demo account for each future signup.
create or replace function public.create_demo_account_for_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.demo_accounts(user_id) values (new.id)
  on conflict (user_id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_demo_account on auth.users;
create trigger on_auth_user_created_demo_account
after insert on auth.users
for each row execute procedure public.create_demo_account_for_new_user();
