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


-- Customer practice transfer to a fictional external bank.
-- Oso Local Bank is fictional: this function only deducts simulated USD funds
-- and records an audit entry. It does not contact a bank or payment network.
alter table public.demo_transactions
  drop constraint if exists demo_transactions_action_check;
alter table public.demo_transactions
  add constraint demo_transactions_action_check
  check (action in ('add','deduct','set','transfer'));

create or replace function public.customer_demo_transfer_oso_local(
  p_amount numeric,
  p_recipient_name text,
  p_account_number text,
  p_description text default ''
)
returns table(new_balance numeric, transaction_id uuid)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_balance numeric(14,2);
  v_new_balance numeric(14,2);
  v_transaction_id uuid;
  v_note text;
begin
  if v_user_id is null then
    raise exception 'Please sign in to make a demo transfer';
  end if;
  if p_recipient_name is null or length(trim(p_recipient_name)) < 2 or length(p_recipient_name) > 100 then
    raise exception 'Enter a valid recipient name';
  end if;
  if p_account_number is null or p_account_number !~ '^[0-9]{8,16}$' then
    raise exception 'Use an 8 to 16 digit fictional account number';
  end if;
  if p_amount is null or p_amount <= 0 or p_amount > 1000000000 then
    raise exception 'Enter a valid transfer amount';
  end if;

  insert into public.demo_accounts(user_id, balance)
  values (v_user_id, 0)
  on conflict (user_id) do nothing;

  select balance into v_balance
  from public.demo_accounts
  where user_id = v_user_id
  for update;

  if v_balance < p_amount then
    raise exception 'Insufficient demo funds. Your available balance is % USD', v_balance;
  end if;

  v_new_balance := v_balance - round(p_amount, 2);
  if v_new_balance < 0 then
    raise exception 'Insufficient demo funds';
  end if;

  v_note := 'Fictional Oso Local Bank | Recipient: ' || trim(p_recipient_name)
    || ' | Account ending ' || right(p_account_number, 4)
    || case when coalesce(trim(p_description), '') <> '' then ' | Description: ' || left(trim(p_description), 120) else '' end;

  update public.demo_accounts
  set balance = v_new_balance, updated_at = now()
  where user_id = v_user_id;

  insert into public.demo_transactions(user_id, action, amount, balance_after, note, created_by)
  values (v_user_id, 'transfer', round(p_amount, 2), v_new_balance, v_note, v_user_id)
  returning id into v_transaction_id;

  return query select v_new_balance, v_transaction_id;
end;
$$;

revoke all on function public.customer_demo_transfer_oso_local(numeric,text,text,text) from public;
grant execute on function public.customer_demo_transfer_oso_local(numeric,text,text,text) to authenticated;


-- Replace the single-bank simulation with a selectable list of fictional banks.
drop function if exists public.customer_demo_transfer_oso_local(numeric,text,text,text);

create or replace function public.customer_demo_transfer_fictional_bank(
  p_bank_name text,
  p_amount numeric,
  p_recipient_name text,
  p_account_number text,
  p_description text default ''
)
returns table(new_balance numeric, transaction_id uuid)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_balance numeric(14,2);
  v_new_balance numeric(14,2);
  v_transaction_id uuid;
  v_note text;
begin
  if v_user_id is null then raise exception 'Please sign in to make a demo transfer'; end if;
  if coalesce((select c.is_blocked from public.customer_access_controls c where c.user_id = v_user_id), false) then
    raise exception 'Transfers are temporarily restricted by the TopSafeB owner. Please contact TopSafeB support.';
  end if;
  if p_bank_name is null or length(trim(p_bank_name)) < 2 or length(trim(p_bank_name)) > 100 then
    raise exception 'Enter a fictional bank name between 2 and 100 characters';
  end if;
  if p_recipient_name is null or length(trim(p_recipient_name)) < 2 or length(p_recipient_name) > 100 then
    raise exception 'Enter a valid recipient name';
  end if;
  if p_account_number is null or p_account_number !~ '^[0-9]{8,16}$' then
    raise exception 'Use an 8 to 16 digit fictional account number';
  end if;
  if p_amount is null or p_amount <= 0 or p_amount > 1000000000 then
    raise exception 'Enter a valid transfer amount';
  end if;

  insert into public.demo_accounts(user_id,balance) values(v_user_id,0)
  on conflict(user_id) do nothing;

  select balance into v_balance from public.demo_accounts
  where user_id=v_user_id for update;

  if v_balance < round(p_amount,2) then
    raise exception 'Insufficient demo funds. Your available balance is % USD',v_balance;
  end if;

  v_new_balance := v_balance - round(p_amount,2);
  v_note := 'Fictional bank: ' || p_bank_name
    || ' | Recipient: ' || trim(p_recipient_name)
    || ' | Account ending ' || right(p_account_number,4)
    || case when coalesce(trim(p_description),'') <> '' then ' | Description: ' || left(trim(p_description),120) else '' end;

  update public.demo_accounts set balance=v_new_balance,updated_at=now()
  where user_id=v_user_id;

  insert into public.demo_transactions(user_id,action,amount,balance_after,note,created_by)
  values(v_user_id,'transfer',round(p_amount,2),v_new_balance,v_note,v_user_id)
  returning id into v_transaction_id;

  return query select v_new_balance,v_transaction_id;
end;
$$;

revoke all on function public.customer_demo_transfer_fictional_bank(text,numeric,text,text,text) from public;
grant execute on function public.customer_demo_transfer_fictional_bank(text,numeric,text,text,text) to authenticated;


-- International demo transfer: fixed educational conversion examples only.
-- No external bank, FX provider, payment rail, or real recipient is contacted.
create or replace function public.customer_demo_transfer_international(
  p_country text,
  p_bank_name text,
  p_amount numeric,
  p_recipient_name text,
  p_account_number text,
  p_description text default ''
)
returns table(new_balance numeric, transaction_id uuid, converted_amount numeric, destination_currency text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_balance numeric(14,2);
  v_new_balance numeric(14,2);
  v_transaction_id uuid;
  v_rate numeric;
  v_currency text;
  v_converted numeric(18,2);
  v_note text;
begin
  if v_user_id is null then raise exception 'Please sign in to make a demo transfer'; end if;
  if coalesce((select c.is_blocked from public.customer_access_controls c where c.user_id = v_user_id), false) then
    raise exception 'Transfers are temporarily restricted by the TopSafeB owner. Please contact TopSafeB support.';
  end if;
  if p_country = 'United Kingdom' then v_currency := 'GBP'; v_rate := 0.79;
  elsif p_country = 'United States' then v_currency := 'USD'; v_rate := 1;
  elsif p_country = 'Canada' then v_currency := 'CAD'; v_rate := 1.36;
  elsif p_country = 'Ghana' then v_currency := 'GHS'; v_rate := 15;
  elsif p_country = 'South Africa' then v_currency := 'ZAR'; v_rate := 18.5;
  elsif p_country = 'Kenya' then v_currency := 'KES'; v_rate := 129;
  elsif p_country = 'India' then v_currency := 'INR'; v_rate := 83;
  elsif p_country = 'Nigeria' then v_currency := 'NGN'; v_rate := 1500;
  elsif p_country = 'Eurozone' then v_currency := 'EUR'; v_rate := 0.95;
  elsif p_country = 'Uganda' then v_currency := 'UGX'; v_rate := 3700;
  elsif p_country = 'Tanzania' then v_currency := 'TZS'; v_rate := 2550;
  elsif p_country = 'Rwanda' then v_currency := 'RWF'; v_rate := 1300;
  elsif p_country = 'Zambia' then v_currency := 'ZMW'; v_rate := 27;
  elsif p_country = 'Botswana' then v_currency := 'BWP'; v_rate := 13.5;
  elsif p_country = 'Egypt' then v_currency := 'EGP'; v_rate := 49;
  elsif p_country = 'Morocco' then v_currency := 'MAD'; v_rate := 10;
  elsif p_country = 'Ethiopia' then v_currency := 'ETB'; v_rate := 57;
  elsif p_country in ('Senegal','Ivory Coast') then v_currency := 'XOF'; v_rate := 600;
  elsif p_country = 'Cameroon' then v_currency := 'XAF'; v_rate := 600;
  elsif p_country = 'Switzerland' then v_currency := 'CHF'; v_rate := 0.9;
  elsif p_country = 'Sweden' then v_currency := 'SEK'; v_rate := 10.5;
  elsif p_country = 'Norway' then v_currency := 'NOK'; v_rate := 10.7;
  elsif p_country = 'Denmark' then v_currency := 'DKK'; v_rate := 7.1;
  elsif p_country = 'Poland' then v_currency := 'PLN'; v_rate := 4;
  elsif p_country = 'Turkey' then v_currency := 'TRY'; v_rate := 32;
  elsif p_country = 'Mexico' then v_currency := 'MXN'; v_rate := 17;
  elsif p_country = 'Brazil' then v_currency := 'BRL'; v_rate := 5;
  elsif p_country = 'China' then v_currency := 'CNY'; v_rate := 7.2;
  elsif p_country = 'Japan' then v_currency := 'JPY'; v_rate := 150;
  elsif p_country = 'Singapore' then v_currency := 'SGD'; v_rate := 1.35;
  elsif p_country = 'Malaysia' then v_currency := 'MYR'; v_rate := 4.7;
  elsif p_country = 'Indonesia' then v_currency := 'IDR'; v_rate := 15600;
  elsif p_country = 'Philippines' then v_currency := 'PHP'; v_rate := 56;
  elsif p_country = 'Thailand' then v_currency := 'THB'; v_rate := 36;
  elsif p_country = 'United Arab Emirates' then v_currency := 'AED'; v_rate := 3.67;
  elsif p_country = 'Saudi Arabia' then v_currency := 'SAR'; v_rate := 3.75;
  elsif p_country = 'Australia' then v_currency := 'AUD'; v_rate := 1.52;
  elsif p_country = 'New Zealand' then v_currency := 'NZD'; v_rate := 1.65;
  elsif p_country = 'Namibia' then v_currency := 'NAD'; v_rate := 18.5;
  elsif p_country = 'Mauritius' then v_currency := 'MUR'; v_rate := 45;
  elsif p_country = 'Seychelles' then v_currency := 'SCR'; v_rate := 13.5;
  elsif p_country = 'Angola' then v_currency := 'AOA'; v_rate := 850;
  elsif p_country = 'Mozambique' then v_currency := 'MZN'; v_rate := 64;
  elsif p_country = 'Malawi' then v_currency := 'MWK'; v_rate := 1700;
  elsif p_country = 'Zimbabwe' then v_currency := 'ZWL'; v_rate := 13;
  elsif p_country = 'Tunisia' then v_currency := 'TND'; v_rate := 3.1;
  elsif p_country = 'Algeria' then v_currency := 'DZD'; v_rate := 134;
  elsif p_country = 'Madagascar' then v_currency := 'MGA'; v_rate := 4500;
  elsif p_country = 'Democratic Republic of the Congo' then v_currency := 'CDF'; v_rate := 2700;
  elsif p_country = 'Liberia' then v_currency := 'LRD'; v_rate := 190;
  elsif p_country = 'Sierra Leone' then v_currency := 'SLE'; v_rate := 22;
  elsif p_country = 'Gambia' then v_currency := 'GMD'; v_rate := 67;
  elsif p_country = 'Lesotho' then v_currency := 'LSL'; v_rate := 18.5;
  elsif p_country = 'Eswatini' then v_currency := 'SZL'; v_rate := 18.5;
  elsif p_country = 'Iceland' then v_currency := 'ISK'; v_rate := 138;
  elsif p_country = 'Czechia' then v_currency := 'CZK'; v_rate := 23;
  elsif p_country = 'Hungary' then v_currency := 'HUF'; v_rate := 360;
  elsif p_country = 'Romania' then v_currency := 'RON'; v_rate := 4.6;
  elsif p_country = 'Bulgaria' then v_currency := 'BGN'; v_rate := 1.86;
  elsif p_country = 'Croatia' then v_currency := 'EUR'; v_rate := 0.95;
  elsif p_country = 'Serbia' then v_currency := 'RSD'; v_rate := 108;
  elsif p_country = 'Ukraine' then v_currency := 'UAH'; v_rate := 39;
  elsif p_country = 'Albania' then v_currency := 'ALL'; v_rate := 93;
  elsif p_country = 'Bosnia and Herzegovina' then v_currency := 'BAM'; v_rate := 1.86;
  elsif p_country = 'North Macedonia' then v_currency := 'MKD'; v_rate := 58;
  elsif p_country = 'Georgia' then v_currency := 'GEL'; v_rate := 2.7;
  elsif p_country = 'Armenia' then v_currency := 'AMD'; v_rate := 390;
  elsif p_country = 'Azerbaijan' then v_currency := 'AZN'; v_rate := 1.7;
  elsif p_country = 'Argentina' then v_currency := 'ARS'; v_rate := 950;
  elsif p_country = 'Chile' then v_currency := 'CLP'; v_rate := 930;
  elsif p_country = 'Colombia' then v_currency := 'COP'; v_rate := 4000;
  elsif p_country = 'Peru' then v_currency := 'PEN'; v_rate := 3.7;
  elsif p_country = 'Uruguay' then v_currency := 'UYU'; v_rate := 39;
  elsif p_country = 'Costa Rica' then v_currency := 'CRC'; v_rate := 510;
  elsif p_country = 'Panama' then v_currency := 'PAB'; v_rate := 1;
  elsif p_country = 'Dominican Republic' then v_currency := 'DOP'; v_rate := 59;
  elsif p_country = 'Jamaica' then v_currency := 'JMD'; v_rate := 156;
  elsif p_country = 'Trinidad and Tobago' then v_currency := 'TTD'; v_rate := 6.8;
  elsif p_country = 'Bahamas' then v_currency := 'BSD'; v_rate := 1;
  elsif p_country = 'Guatemala' then v_currency := 'GTQ'; v_rate := 7.7;
  elsif p_country = 'South Korea' then v_currency := 'KRW'; v_rate := 1350;
  elsif p_country = 'Hong Kong' then v_currency := 'HKD'; v_rate := 7.8;
  elsif p_country = 'Taiwan' then v_currency := 'TWD'; v_rate := 32;
  elsif p_country = 'Vietnam' then v_currency := 'VND'; v_rate := 24500;
  elsif p_country = 'Pakistan' then v_currency := 'PKR'; v_rate := 278;
  elsif p_country = 'Bangladesh' then v_currency := 'BDT'; v_rate := 110;
  elsif p_country = 'Sri Lanka' then v_currency := 'LKR'; v_rate := 300;
  elsif p_country = 'Nepal' then v_currency := 'NPR'; v_rate := 133;
  elsif p_country = 'Qatar' then v_currency := 'QAR'; v_rate := 3.64;
  elsif p_country = 'Kuwait' then v_currency := 'KWD'; v_rate := 0.31;
  elsif p_country = 'Bahrain' then v_currency := 'BHD'; v_rate := 0.38;
  elsif p_country = 'Oman' then v_currency := 'OMR'; v_rate := 0.385;
  elsif p_country = 'Jordan' then v_currency := 'JOD'; v_rate := 0.71;
  elsif p_country = 'Israel' then v_currency := 'ILS'; v_rate := 3.7;
  elsif p_country = 'Iraq' then v_currency := 'IQD'; v_rate := 1310;
  elsif p_country = 'Kazakhstan' then v_currency := 'KZT'; v_rate := 470;
  elsif p_country = 'Uzbekistan' then v_currency := 'UZS'; v_rate := 12500;
  elsif p_country = 'Cambodia' then v_currency := 'KHR'; v_rate := 4100;
  elsif p_country = 'Laos' then v_currency := 'LAK'; v_rate := 22000;
  elsif p_country = 'Myanmar' then v_currency := 'MMK'; v_rate := 2100;
  elsif p_country = 'Fiji' then v_currency := 'FJD'; v_rate := 2.25;
  elsif p_country = 'Papua New Guinea' then v_currency := 'PGK'; v_rate := 3.8;
  elsif p_country = 'Samoa' then v_currency := 'WST'; v_rate := 2.7;
  elsif p_country = 'Tonga' then v_currency := 'TOP'; v_rate := 2.35;
  elsif p_country = 'Vanuatu' then v_currency := 'VUV'; v_rate := 120;
  elsif p_country = 'Solomon Islands' then v_currency := 'SBD'; v_rate := 8.4;
  else raise exception 'Choose a supported demo destination country'; end if;

  if p_bank_name is null or length(trim(p_bank_name)) < 2 or length(p_bank_name) > 100 then
    raise exception 'Enter a fictional receiving bank name (2 to 100 characters)';
  end if;
  if p_recipient_name is null or length(trim(p_recipient_name)) < 2 or length(p_recipient_name) > 100 then
    raise exception 'Enter a valid recipient name';
  end if;
  if p_account_number is null or p_account_number !~ '^[0-9]{8,16}$' then
    raise exception 'Use an 8 to 16 digit fictional account number';
  end if;
  if p_amount is null or p_amount <= 0 or p_amount > 1000000000 then
    raise exception 'Enter a valid transfer amount';
  end if;

  insert into public.demo_accounts(user_id,balance) values(v_user_id,0)
  on conflict(user_id) do nothing;
  select balance into v_balance from public.demo_accounts
  where user_id=v_user_id for update;

  if v_balance < round(p_amount,2) then
    raise exception 'Insufficient demo funds. Your available balance is % USD',v_balance;
  end if;
  v_new_balance := v_balance - round(p_amount,2);
  v_converted := round(round(p_amount,2) * v_rate, 2);
  v_note := 'SIMULATED INTERNATIONAL TRANSFER | Country: ' || p_country
    || ' | Fictional bank: ' || p_bank_name
    || ' | Recipient: ' || trim(p_recipient_name)
    || ' | Account ending ' || right(p_account_number,4)
    || ' | Example conversion: ' || v_converted || ' ' || v_currency
    || ' (not a live FX rate)'
    || case when coalesce(trim(p_description),'') <> '' then ' | Description: ' || left(trim(p_description),120) else '' end;

  update public.demo_accounts set balance=v_new_balance,updated_at=now()
  where user_id=v_user_id;
  insert into public.demo_transactions(user_id,action,amount,balance_after,note,created_by)
  values(v_user_id,'transfer',round(p_amount,2),v_new_balance,v_note,v_user_id)
  returning id into v_transaction_id;

  return query select v_new_balance,v_transaction_id,v_converted,v_currency;
end;
$$;
revoke all on function public.customer_demo_transfer_international(text,text,numeric,text,text,text) from public;
grant execute on function public.customer_demo_transfer_international(text,text,numeric,text,text,text) to authenticated;


-- Customer-requested demo top-ups. Requests never change a balance until an
-- authorised owner approves them through the admin_review_demo_topup RPC.
create table if not exists public.demo_topup_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  amount numeric(14,2) not null check (amount >= 1 and amount <= 1000000000),
  note text not null default '',
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  owner_note text not null default '',
  reviewed_by uuid references auth.users(id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists demo_topup_requests_created_idx
  on public.demo_topup_requests(status, created_at desc);
alter table public.demo_topup_requests enable row level security;
drop policy if exists "Customers can submit own demo top-up requests" on public.demo_topup_requests;
create policy "Customers can submit own demo top-up requests"
on public.demo_topup_requests for insert to authenticated
with check (auth.uid() = user_id and status = 'pending');
drop policy if exists "Customers and admins can view demo top-up requests" on public.demo_topup_requests;
create policy "Customers and admins can view demo top-up requests"
on public.demo_topup_requests for select to authenticated
using (auth.uid() = user_id or exists (
  select 1 from public.admin_users a where a.user_id = auth.uid()
));

create or replace function public.admin_review_demo_topup(
  p_request_id uuid,
  p_decision text,
  p_owner_note text default ''
)
returns table(request_status text, new_balance numeric)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_request public.demo_topup_requests%rowtype;
  v_balance numeric(14,2);
  v_new_balance numeric(14,2);
begin
  if auth.uid() is null or not exists (
    select 1 from public.admin_users where user_id = auth.uid()
  ) then raise exception 'Administrator access required'; end if;
  if p_decision not in ('approve','reject') then raise exception 'Choose approve or reject'; end if;

  select * into v_request from public.demo_topup_requests
  where id = p_request_id for update;
  if not found then raise exception 'Top-up request not found'; end if;
  if v_request.status <> 'pending' then raise exception 'This request has already been reviewed'; end if;

  if p_decision = 'approve' then
    insert into public.demo_accounts(user_id,balance) values(v_request.user_id,0)
    on conflict(user_id) do nothing;
    select balance into v_balance from public.demo_accounts
    where user_id = v_request.user_id for update;
    v_new_balance := v_balance + v_request.amount;
    if v_new_balance > 999999999999.99 then raise exception 'Demo balance limit exceeded'; end if;
    update public.demo_accounts set balance=v_new_balance,updated_at=now()
    where user_id=v_request.user_id;
    insert into public.demo_transactions(user_id,action,amount,balance_after,note,created_by)
    values(v_request.user_id,'add',v_request.amount,v_new_balance,
      'Customer demo top-up request approved | ' || left(coalesce(v_request.note,''),200),
      auth.uid());
  else
    v_new_balance := null;
  end if;

  update public.demo_topup_requests
  set status=case when p_decision='approve' then 'approved' else 'rejected' end,
      owner_note=left(coalesce(p_owner_note,''),250),
      reviewed_by=auth.uid(),reviewed_at=now()
  where id=p_request_id;
  return query select case when p_decision='approve' then 'approved' else 'rejected' end,v_new_balance;
end;
$$;
revoke all on function public.admin_review_demo_topup(uuid,text,text) from public;
grant execute on function public.admin_review_demo_topup(uuid,text,text) to authenticated;
