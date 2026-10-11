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
