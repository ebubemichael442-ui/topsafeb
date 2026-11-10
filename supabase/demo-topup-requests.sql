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
