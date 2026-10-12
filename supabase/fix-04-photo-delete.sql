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
