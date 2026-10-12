-- ============================================================
--  车协回忆录 · 新项目一次安装（新加坡区域）
--  用法：全部内容粘进新项目的 SQL Editor，点 Run。
--  顺序：建表 → 撤回策略 → 加照片申请 → 注册审核 → 仅管理员可删
--  （后面补丁会覆盖前面同名策略，最终状态以最后为准；可重复运行）
-- ============================================================

-- ####################  schema.sql  ####################
-- ============================================================
--  车协回忆录 · Supabase 数据库结构
--  用法：全部内容粘进 Supabase 的 SQL Editor，点 Run。
--  可以重复运行（幂等）。
--
--  注意：建项目时关闭了「自动暴露新表」，所以第 4 节必须显式授权，
--        否则接口会一律返回 401（表存在但角色没有访问权）。
-- ============================================================

-- ---------- 1. 用户档案 ----------
create table if not exists public.profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  is_admin     boolean not null default false,
  created_at   timestamptz not null default now()
);

-- 注册后自动建档案
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, coalesce(new.raw_user_meta_data->>'display_name', split_part(new.email, '@', 1)))
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- 判断当前用户是否管理员（security definer，避免 RLS 递归）
create or replace function public.is_admin()
returns boolean
language sql
security definer set search_path = public
stable
as $$
  select coalesce((select p.is_admin from public.profiles p where p.id = auth.uid()), false);
$$;

-- ---------- 2. 作品表 ----------
create table if not exists public.works (
  id             uuid primary key default gen_random_uuid(),
  created_at     timestamptz not null default now(),
  date           date,
  place          text not null,
  city           text,
  caption        text,
  author_display text,
  tags           text[] not null default '{}',
  photos         text[] not null default '{}',
  cover          text,
  status         text not null default 'pending'
                 check (status in ('pending','published','rejected')),
  uploader       uuid references auth.users(id),
  reviewed_by    uuid references auth.users(id),
  reviewed_at    timestamptz,
  reject_reason  text
);

create index if not exists works_status_date_idx on public.works (status, date desc);
create index if not exists works_uploader_idx    on public.works (uploader);

-- ---------- 3. 行级安全（RLS）----------
alter table public.profiles enable row level security;
alter table public.works    enable row level security;

drop policy if exists profiles_self_read on public.profiles;
create policy profiles_self_read on public.profiles
  for select to authenticated
  using (id = auth.uid() or public.is_admin());

drop policy if exists profiles_self_update on public.profiles;
create policy profiles_self_update on public.profiles
  for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

drop policy if exists works_public_read on public.works;
create policy works_public_read on public.works
  for select to anon, authenticated
  using (status = 'published');

drop policy if exists works_own_read on public.works;
create policy works_own_read on public.works
  for select to authenticated
  using (uploader = auth.uid());

-- works：管理员能读全部（含别人待审的）—— 审核页靠这条
drop policy if exists works_admin_read on public.works;
create policy works_admin_read on public.works
  for select to authenticated
  using (public.is_admin());

drop policy if exists works_insert_pending on public.works;
create policy works_insert_pending on public.works
  for insert to authenticated
  with check (uploader = auth.uid() and status = 'pending');

drop policy if exists works_delete_own_pending on public.works;
create policy works_delete_own_pending on public.works
  for delete to authenticated
  using (uploader = auth.uid() and status = 'pending');

drop policy if exists works_admin_update on public.works;
create policy works_admin_update on public.works
  for update to authenticated
  using (public.is_admin())
  with check (public.is_admin());

drop policy if exists works_admin_delete on public.works;
create policy works_admin_delete on public.works
  for delete to authenticated
  using (public.is_admin());

-- ---------- 4. 显式授权（关键！少了这节接口会 401）----------
grant usage on schema public to anon, authenticated;

-- 作品：未登录也能读（RLS 只放行 published）；登录用户可提交与撤回
grant select on public.works to anon, authenticated;
grant insert, delete on public.works to authenticated;
grant update on public.works to authenticated;          -- 实际只有管理员能用（RLS 管着）

-- 用户档案：登录用户可读；只能改昵称，改不了 is_admin
grant select on public.profiles to authenticated;
revoke update on public.profiles from authenticated;
grant update (display_name) on public.profiles to authenticated;

grant execute on function public.is_admin() to anon, authenticated;

-- ---------- 5. 照片存储 ----------
-- 桶名 photos，公开读；路径：pending/<用户id>/xxx.jpg 与 published/<作品id>/xxx.jpg
insert into storage.buckets (id, name, public)
values ('photos', 'photos', true)
on conflict (id) do update set public = true;

drop policy if exists photos_public_read on storage.objects;
create policy photos_public_read on storage.objects
  for select to anon, authenticated
  using (bucket_id = 'photos');

drop policy if exists photos_upload_own on storage.objects;
create policy photos_upload_own on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'photos'
    and (storage.foldername(name))[1] = 'pending'
    and (storage.foldername(name))[2] = auth.uid()::text
  );

drop policy if exists photos_admin_all on storage.objects;
create policy photos_admin_all on storage.objects
  for all to authenticated
  using (bucket_id = 'photos' and public.is_admin())
  with check (bucket_id = 'photos' and public.is_admin());

-- 上传者可以撤回（删除）自己还没通过的照片 —— 「我的投稿」页的撤回功能靠这条
drop policy if exists photos_delete_own on storage.objects;
create policy photos_delete_own on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'photos'
    and (storage.foldername(name))[1] = 'pending'
    and (storage.foldername(name))[2] = auth.uid()::text
  );

-- ============================================================
--  6. 自检：跑完之后看这几行输出
-- ============================================================
select 'tables' as check_item,
       (select count(*) from information_schema.tables
         where table_schema = 'public' and table_name in ('works','profiles')) as value
union all
select 'works policies',
       (select count(*) from pg_policies where schemaname = 'public' and tablename = 'works')
union all
select 'storage policies',
       (select count(*) from pg_policies where schemaname = 'storage' and tablename = 'objects')
union all
select 'bucket photos',
       (select count(*) from storage.buckets where id = 'photos');

-- ============================================================
--  7. 把自己设成管理员
--  先在前端注册一个账号，再把下面这句的邮箱改成你的，单独 Run 这一段。
-- ============================================================
-- update public.profiles
--    set is_admin = true
--  where id = (select id from auth.users where email = '你的邮箱@example.com');
--
-- 查看谁是管理员：
-- select u.email, p.display_name, p.is_admin
--   from public.profiles p join auth.users u on u.id = p.id;


-- ####################  fix-01-storage-delete.sql  ####################
-- ============================================================
--  补丁 01：撤回功能所需的存储策略
--
--  用法：全部内容粘进 Supabase 的 SQL Editor，点 Run。
--  可以重复运行（幂等）。
-- ============================================================

-- ① 允许上传者删除自己还没通过的照片
--    「我的投稿」页的"撤回并删除"按钮靠这条策略；
--    没有它，同学撤回时记录会删掉但照片留在存储里变成垃圾。
drop policy if exists photos_delete_own on storage.objects;
create policy photos_delete_own on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'photos'
    and (storage.foldername(name))[1] = 'pending'
    and (storage.foldername(name))[2] = auth.uid()::text
  );

-- ② 顺带把还没验证邮箱的账号标记为已验证
--    （邮箱验证已经关掉了，这样这些账号也能直接登录）
update auth.users
   set email_confirmed_at = now()
 where email_confirmed_at is null;

-- ③ 看结果：第一行应该是 1
select 'photos_delete_own 策略' as 检查项,
       (select count(*) from pg_policies
         where schemaname = 'storage' and tablename = 'objects'
           and policyname = 'photos_delete_own')::text as 结果
union all
select '已验证账号数', (select count(*) from auth.users where email_confirmed_at is not null)::text
union all
select '未验证账号数', (select count(*) from auth.users where email_confirmed_at is null)::text
union all
select '作品总数',     (select count(*) from public.works)::text;


-- ####################  fix-02-photo-requests.sql  ####################
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


-- ####################  fix-03-member-approval.sql  ####################
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


-- ####################  fix-04-photo-delete.sql  ####################
-- ============================================================
--  补丁 04：删除照片 / 作品集 —— 仅管理员
--
--  用法：全部内容粘进 Supabase 的 SQL Editor，点 Run。
--  可以重复运行（幂等）。
--
--  规则：
--    · 管理员：可以删除任何作品集、任何照片
--    · 上传者：不能删除已提交的作品集，也不能删除里面的照片
--      （待审的作品集同样不能自己删——需要删除就找管理员）
--    · 例外：加照片申请在【尚未被处理】时，申请人可以自己撤回
--      （那只是取消一个申请，不是删已公开的内容）
-- ============================================================

-- ---------- 1. 移除"上传者可以删自己作品"的权限 ----------
drop policy if exists works_delete_own_pending on public.works;
drop policy if exists works_delete_own         on public.works;
-- 删除权限现在只剩 works_admin_delete（本来就在，只有管理员能用）

-- ---------- 2. 从作品集里移除一张照片（函数内校验管理员身份）----------
create or replace function public.remove_work_photo(p_work uuid, p_path text)
returns text[]
language plpgsql security definer set search_path = public
as $$
declare
  v_new   text[];
  v_cover text;
begin
  if not public.is_admin() then
    raise exception '只有管理员能删除照片';
  end if;
  if p_path is null or p_path = '' then
    raise exception '照片路径为空';
  end if;

  update public.works
     set photos = array_remove(photos, p_path)
   where id = p_work
  returning photos, cover into v_new, v_cover;

  if v_new is null then
    raise exception '作品集不存在';
  end if;

  -- 被删的正好是封面，或封面已不在列表里 → 用剩下的第一张顶上
  if v_cover = p_path or v_cover is null or not (v_cover = any(v_new)) then
    update public.works
       set cover = case when coalesce(array_length(v_new, 1), 0) >= 1 then v_new[1] else null end
     where id = p_work;
  end if;

  return v_new;
end;
$$;

-- ---------- 3. 存储删除策略 ----------
-- 不创建"作品上传者可删"的策略 —— 已公开目录里的照片只有管理员能删
-- （管理员由 photos_admin_all 覆盖，它是 for all）
drop policy if exists photos_delete_work_owner on storage.objects;

-- 仅保留一条：申请人撤回"尚未被处理的加照片申请"时，删掉自己刚上传的照片
drop policy if exists photos_delete_own on storage.objects;
create policy photos_delete_own on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'photos'
    and (storage.foldername(name))[1] = 'pending'
    and (storage.foldername(name))[2] = auth.uid()::text
    and public.is_approved()
  );

-- ---------- 4. 授权 ----------
grant execute on function public.remove_work_photo(uuid, text) to authenticated;

-- ---------- 5. 自检 ----------
select 'works 删除策略（只应有管理员那 1 条）' as 检查项,
       (select count(*) from pg_policies
         where schemaname='public' and tablename='works' and cmd='DELETE')::text as 结果
union all
select '残留的上传者删除策略（应为 0）',
       (select count(*) from pg_policies
         where schemaname='public' and tablename='works'
           and policyname in ('works_delete_own','works_delete_own_pending'))::text
union all
select '已公开照片的上传者删除策略（应为 0）',
       (select count(*) from pg_policies
         where schemaname='storage' and tablename='objects'
           and policyname='photos_delete_work_owner')::text
union all
select 'remove_work_photo 函数（应为 1）',
       (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
         where n.nspname='public' and p.proname='remove_work_photo')::text
union all
select '管理员删除策略 works_admin_delete（应为 1）',
       (select count(*) from pg_policies
         where schemaname='public' and tablename='works'
           and policyname='works_admin_delete')::text;


-- ####################  最终自检（跑完看这张表）  ####################
select 'tables（应为 3）' as 检查项,
       (select count(*) from information_schema.tables
         where table_schema='public' and table_name in ('works','profiles','photo_requests'))::text as 结果
union all select 'works 策略数（应为 7）',
       (select count(*) from pg_policies where schemaname='public' and tablename='works')::text
union all select 'photo_requests 策略数（应为 4）',
       (select count(*) from pg_policies where schemaname='public' and tablename='photo_requests')::text
union all select 'storage 策略数（应为 5）',
       (select count(*) from pg_policies where schemaname='storage' and tablename='objects')::text
union all select 'bucket photos（应为 1）',
       (select count(*) from storage.buckets where id='photos')::text
union all select '函数 is_admin / is_approved / review_member',
       (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
         where n.nspname='public' and p.proname in ('is_admin','is_approved','review_member'))::text
union all select '函数 approve_photo_request / remove_work_photo',
       (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
         where n.nspname='public' and p.proname in ('approve_photo_request','remove_work_photo'))::text
union all select '作品数（应为 0）', (select count(*) from public.works)::text
union all select '账号数（应为 0）', (select count(*) from public.profiles)::text;
