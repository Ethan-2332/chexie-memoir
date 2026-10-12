-- ============================================================
--  补丁 05：添加 / 解除管理员
--
--  用法：全部内容粘进 Supabase 的 SQL Editor，点 Run。可重复运行。
--
--  为什么必须用函数：
--    profiles 表对普通用户只授权了改 display_name（见 schema.sql 第 4 节），
--    is_admin 字段前端根本改不动 —— 这是防止有人给自己提权。
--    所以换管理员只能走下面这个 security definer 函数，它内部校验调用者身份。
--
--  安全护栏：
--    · 只有管理员能调用
--    · 不能取消自己的管理员（否则一次误点就把自己关在门外）
--    · 不能把最后一个管理员取消掉
-- ============================================================

create or replace function public.set_admin(p_user uuid, p_is_admin boolean)
returns void
language plpgsql
security definer set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception '只有管理员能设置管理员';
  end if;

  if p_user is null then
    raise exception '用户不存在';
  end if;

  -- 取消自己的管理员：禁止（要降级自己只能走 SQL，避免误操作把自己锁死）
  if p_user = auth.uid() and p_is_admin = false then
    raise exception '不能取消自己的管理员身份';
  end if;

  -- 取消别人时，保证至少还剩一个管理员
  if p_is_admin = false then
    if (select count(*) from public.profiles
         where is_admin = true and id <> p_user) = 0 then
      raise exception '至少要保留一个管理员';
    end if;
  end if;

  update public.profiles
     set is_admin = p_is_admin
   where id = p_user;

  if not found then
    raise exception '找不到这个用户';
  end if;

  -- 设为管理员时，顺手把注册审核也放行（管理员天然视为已通过）
  if p_is_admin = true then
    update public.profiles
       set status = 'approved', status_reason = null
     where id = p_user and status <> 'approved';
  end if;
end;
$$;

grant execute on function public.set_admin(uuid, boolean) to authenticated;

-- ---------- 自检 ----------
select 'set_admin 函数已建（应为 1）' as 检查项,
       (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = 'set_admin')::text as 结果
union all
select '当前管理员人数',
       (select count(*) from public.profiles where is_admin = true)::text
union all
select '成员总数',
       (select count(*) from public.profiles)::text
union all
select '管理员名单',
       coalesce((select string_agg(coalesce(display_name, email, id::text), '、')
                   from public.profiles where is_admin = true), '（无）');
