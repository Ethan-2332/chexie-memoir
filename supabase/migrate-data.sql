-- ============================================================
--  车协回忆录 · 把旧项目的数据搬到新项目
--  前提：你已经在新项目里【注册过至少一个账号】
--  用法：粘进新项目的 SQL Editor，Run。可重复运行。
-- ============================================================

-- ① 把最早注册的账号设为管理员 + 直接通过审核
update public.profiles
   set is_admin = true, status = 'approved', status_reason = null
 where id = (select id from auth.users order by created_at asc limit 1);

-- ② 迁移作品记录（照片在 git 仓库里，路径是相对路径，不用搬文件）
insert into public.works
  (date, place, city, caption, author_display, tags, photos, cover, status, uploader)
select v.date, v.place, v.city, v.caption, v.author_display, v.tags, v.photos, v.cover,
       'published', (select id from auth.users order by created_at asc limit 1)
  from (values
  -- 跳过（照片在 Supabase 存储里，需要重新上传）：1
    ('2026-10-11'::date, '天目湖-大溪水库', null, '今天真的好累', 'zyh', '{}'::text[], array['photos/w001/1.jpg','photos/w001/2.jpg','photos/w001/3.jpg','photos/w001/4.jpg','photos/w001/5.jpg','photos/w001/6.jpg']::text[], 'photos/w001/1.jpg')
  ) as v(date, place, city, caption, author_display, tags, photos, cover)
 where not exists (select 1 from public.works w2 where w2.place = v.place and w2.date = v.date);

-- ③ 看结果
select u.email, p.display_name, p.is_admin, p.status,
       (select count(*) from public.works) as 作品数
  from public.profiles p join auth.users u on u.id = p.id
 order by u.created_at asc;