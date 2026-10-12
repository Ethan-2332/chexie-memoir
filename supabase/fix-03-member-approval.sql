-- ============================================================
--  补丁 03：注册审核（新用户需要管理员点"通过"才能上传）
--
--  用法：全部内容粘进 Supabase 的 SQL Editor，点 Run。
--  可以重复运行（幂等）。
--
--  效果：
--    · 新注册的账号 status = 'pending'，能登录、能浏览，
--      但【数据库层面】不允许上传作品 / 上传照片 / 申请加照片
--    · 已有账号自动设为 'approved'，不受影响
--    · 管理员在「成员审核」页点通过 / 拒绝
--
--  安全说明：状态只能通过 review_member() 函数修改，
--            该函数内部校验 is_admin()，前端无法自己给自己放行。
-- ============================================================

-- ---------- 1. profiles 增加字段 ----------
-- 注意顺序：先加可空列 → 回填 → 再设默认值和约束。
-- 这样无论跑多少次，都只会把"刚加列时的老账号"设为已通过，
-- 绝不会把后来正在等待审核的人误放行。
alter table public.profiles add column if not exists status        text;
alter table public.profiles add column if not exists status_reason text;
alter table public.profiles add column if not exists email         text;

update public.profiles set status = 'approved' where status is null;

alter table public.profiles alter column status set default 'pending';
alter table public.profiles alter column status set not null;

alter table public.profiles drop constraint if exists profiles_status_chk;
alter table public.profiles add  constraint profiles_status_chk
  check (status in ('pending','approved','rejected'));

-- 把已有账号的邮箱补进档案（审核时要看得到申请人是谁）
update public.profiles p
   set email = u.email
  from auth.users u
 where u.id = p.id and (p.email is null or p.email = '');

-- ---------- 2. 注册时自动建档案，并带上邮箱 ----------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, display_name, email)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'display_name', split_part(new.email, '@', 1)),
    new.email
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

-- ---------- 3. 判断"是否已通过审核" ----------
create or replace function public.is_approved()
returns boolean
language sql
security definer set search_path = public
stable
as $$
  select public.is_admin()
      or exists (select 1 from public.profiles p
                  where p.id = auth.uid() and p.status = 'approved');
$$;

-- ---------- 4. 审核成员的函数（唯一能改 status 的入口）----------
create or replace function public.review_member(
  p_user   uuid,
  p_status text,
  p_reason text default null
)
returns void
language plpgsql
security definer set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception '只有管理员能审核成员';
  end if;
  if p_status not in ('approved','rejected','pending') then
    raise exception '状态不合法：%', p_status;
  end if;
  if p_user = auth.uid() then
    raise exception '不能审核自己的账号';
  end if;

  update public.profiles
     set status = p_status,
         status_reason = p_reason
   where id = p_user;

  if not found then
    raise exception '找不到这个用户';
  end if;
end;
$$;

-- ---------- 5. 把"上传类"策略改成需要已通过审核 ----------
-- 作品：提交 / 撤回
drop policy if exists works_insert_pending on public.works;
create policy works_insert_pending on public.works
  for insert to authenticated
  with check (uploader = auth.uid() and status = 'pending' and public.is_approved());

drop policy if exists works_delete_own_pending on public.works;
create policy works_delete_own_pending on public.works
  for delete to authenticated
  using (uploader = auth.uid() and status = 'pending' and public.is_approved());

-- 照片存储：上传 / 撤回
drop policy if exists photos_upload_own on storage.objects;
create policy photos_upload_own on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'photos'
    and (storage.foldername(name))[1] = 'pending'
    and (storage.foldername(name))[2] = auth.uid()::text
    and public.is_approved()
  );

drop policy if exists photos_delete_own on storage.objects;
create policy photos_delete_own on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'photos'
    and (storage.foldername(name))[1] = 'pending'
    and (storage.foldername(name))[2] = auth.uid()::text
    and public.is_approved()
  );

-- 加照片申请：提交
drop policy if exists pr_insert on public.photo_requests;
create policy pr_insert on public.photo_requests
  for insert to authenticated
  with check (requester = auth.uid() and status = 'pending' and public.is_approved());

-- ---------- 6. 授权 ----------
-- 注意：故意【不】把 update(status) 授给 authenticated，
--       否则任何人改自己的档案就能给自己放行。改状态只能走 review_member()。
grant execute on function public.is_approved()                     to anon, authenticated;
grant execute on function public.review_member(uuid, text, text)   to authenticated;

-- ---------- 7. 自检 ----------
select '我自己的状态' as 检查项,
       coalesce((select status from public.profiles where id = auth.uid()), '（没登录）') as 结果
union all
select '待审核人数',
       (select count(*) from public.profiles where status = 'pending')::text
union all
select '已通过人数',
       (select count(*) from public.profiles where status = 'approved')::text
union all
select 'is_approved 函数已建',
       (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = 'is_approved')::text
union all
select 'review_member 函数已建',
       (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = 'review_member')::text
union all
select '邮箱已补全的人数',
       (select count(*) from public.profiles where email is not null and email <> '')::text;
