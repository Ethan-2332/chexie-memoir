/* ============================================================
   站点配置
   ⚠ SUPABASE_KEY 用的是 publishable key —— 它设计上就是公开的，
     会出现在网页源码里，任何人都看得到。真正的权限由数据库的
     RLS 规则控制（见 supabase/schema.sql），所以公开它没有风险。
   ⚠ 绝对不要把 secret key / service_role key 写进这个文件。
   ============================================================ */
window.APP_CONFIG = {
  SUPABASE_URL: "https://jttakspxfmyurdeccyul.supabase.co",
  SUPABASE_KEY: "sb_publishable_D8SpjqyhXW68VCIUKZ8naw_5Wuz16VK",

  SITE_TITLE: "河海大学自行车协会 · 骑行回忆录",
  SITE_SUBTITLE: "收集同学们的骑行照片，按日期和地点翻阅",

  PHOTO_BUCKET: "photos",       // 照片桶名（见 schema.sql）
  ADMIN_EMAIL: ""               // 可留空；填了会在审核页做一次前端提示
};
