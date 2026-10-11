-- ============================================================
--  补丁 02：作品集「加照片申请」
--
--  用法：全部内容粘进 Supabase 的 SQL Editor，点 Run。
--  可以重复运行（幂等）。
--
--  流程：
--    同学在首页某个作品集右下角点「+」→ 选照片 + 留言 → 提交
--    → 照片上传到 pending/<他的uid>/req-<时间戳>/，同时写入一条申请
--    → 作品集作者（和所有管理员）在「申请审核」页看到
--    → 通过后：照片被并入该作品集的 photos 数组，立刻公开显示
-- ============================================================

-- ---------- 1. 申请表 ----------
create table if not exists public.photo_requests (
  id            uuid primary key default gen_random_uuid(),
  work_id       uuid not null references public.works(id) on delete cascade,
  requester     uuid not null references auth.users(id) on delete cascade,
  message       text,
  photos        text[] not null default '{}',
  status        text not null default 'pending'
                check (status in ('pending','approved','rejected')),
  created_at    timestamptz not null default now(),
  reviewed_by   uuid references auth.users(id),
  reviewed_at   timestamptz,
  reject_reason text
);

create index if not exists pr_work_idx      on public.photo_requests (work_id);
create index if not exists pr_status_idx    on public.photo_requests (status);
create index if not exists pr_requester_idx on public.photo_requests (requester);

alter table public.photo_requests enable row level security;

-- ---------- 2. 权限判断函数 ----------
-- 当前用户是不是这个作品集的作者
create or replace function public.is_work_author(p_work uuid)
returns boolean
language sql security definer set search_path = public stable
as $$
  select exists (select 1 from public.works w where w.id = p_work and w.uploader = auth.uid());
$$;

-- 当前用户能不能审这个作品集的加照片申请（作者本人 或 管理员）
create or replace function public.can_review_work(p_work uuid)
returns boolean
language sql security definer set search_path = public stable
as $$
  select public.is_admin()
      or exists (select 1 from public.works w where w.id = p_work and w.uploader = auth.uid());
$$;

-- ---------- 3. 策略 ----------
-- 只有登录用户能提交，且只能以自己的身份提交、只能提交待审状态
drop policy if exists pr_insert on public.photo_requests;
create policy pr_insert on public.photo_requests
  for insert to authenticated
  with check (requester = auth.uid() and status = 'pending');

-- 申请人能看自己的申请；作品集作者和管理员能看该作品集的全部申请
drop policy if exists pr_read on public.photo_requests;
create policy pr_read on public.photo_requests
  for select to authenticated
  using (requester = auth.uid() or public.can_review_work(work_id));

-- 作者/管理员可以改状态（驳回走这条；通过请用下面的函数，保证照片真被并入）
drop policy if exists pr_review_update on public.photo_requests;
create policy pr_review_update on public.photo_requests
  for update to authenticated
  using (public.can_review_work(work_id))
  with check (public.can_review_work(work_id));

-- 申请人可以撤回自己还没被处理的申请
drop policy if exists pr_delete_own on public.photo_requests;
create policy pr_delete_own on public.photo_requests
  for delete to authenticated
  using (requester = auth.uid() and status = 'pending');

-- ---------- 4. 通过申请（用函数做，保证原子性） ----------
-- 为什么要用函数：作品集作者不是管理员，按原有策略改不了 works 表；
-- 这个函数以 definer 身份执行，但内部会自己检查权限，不会变成后门。
create or replace function public.approve_photo_request(p_request uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_work   uuid;
  v_status text;
  v_photos text[];
  v_cover  text;
begin
  select work_id, status, photos into v_work, v_status, v_photos
    from public.photo_requests where id = p_request;

  if v_work is null then
    raise exception '申请不存在';
  end if;
  if not public.can_review_work(v_work) then
    raise exception '你没有权限审核这个申请';
  end if;
  if v_status <> 'pending' then
    raise exception '这个申请已经处理过了';
  end if;

  select coalesce(cover, case when array_length(photos,1) >= 1 then photos[1] else null end)
    into v_cover from public.works where id = v_work;

  update public.works w
     set photos = coalesce(w.photos, '{}'::text[]) || v_photos,
         cover  = coalesce(v_cover, v_photos[1])
   where w.id = v_work;

  update public.photo_requests
     set status = 'approved',
         reviewed_by = auth.uid(),
         reviewed_at = now()
   where id = p_request;
end;
$$;

-- ---------- 5. 显式授权（项目关闭了自动暴露，必须授权） ----------
grant select                       on public.photo_requests to authenticated;
grant insert, delete               on public.photo_requests to authenticated;
grant update                       on public.photo_requests to authenticated;
grant execute on function public.is_work_author(uuid)      to authenticated;
grant execute on function public.can_review_work(uuid)     to authenticated;
grant execute on function public.approve_photo_request(uuid) to authenticated;

-- ---------- 6. 自检 ----------
select 'photo_requests 策略数' as 检查项,
       (select count(*) from pg_policies
         where schemaname='public' and tablename='photo_requests')::text as 结果
union all
select 'approve 函数已建',
       (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
         where n.nspname='public' and p.proname='approve_photo_request')::text
union all
select 'can_review_work 已建',
       (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
         where n.nspname='public' and p.proname='can_review_work')::text
union all
select '现有申请数',
       (select count(*) from public.photo_requests)::text;
