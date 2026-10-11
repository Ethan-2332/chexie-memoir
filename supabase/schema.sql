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
