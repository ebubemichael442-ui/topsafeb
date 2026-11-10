-- TopSafeB: private owner replies to customer feedback
-- Run once in the Supabase SQL Editor.
-- Adds owner replies and lets each signed-in customer read only their own feedback rows.

alter table public.customer_feedback
  add column if not exists owner_reply text,
  add column if not exists replied_at timestamptz;

alter table public.customer_feedback
  drop constraint if exists customer_feedback_owner_reply_length_check;

alter table public.customer_feedback
  add constraint customer_feedback_owner_reply_length_check
  check (owner_reply is null or char_length(owner_reply) <= 3000);

drop policy if exists "Customers can view own feedback and replies" on public.customer_feedback;
create policy "Customers can view own feedback and replies"
on public.customer_feedback
for select
to authenticated
using (auth.uid() = user_id);

-- The existing "Admins can update customer feedback status" policy
-- already permits authorised administrators to save owner_reply and replied_at.
