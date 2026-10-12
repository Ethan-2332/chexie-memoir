/* ============================================================
   公共脚本：Supabase 客户端、登录态、导航栏、照片地址解析
   所有页面都先引 vendor/supabase.js，再引 config.js，最后引本文件。
   ============================================================ */
(function () {
  const cfg = window.APP_CONFIG;

  if (!window.supabase || !window.supabase.createClient) {
    console.error("supabase.js 未加载");
    return;
  }

  const sb = window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_KEY);
  window.sb = sb;

  // 站点版本号：每次改动手动 +1，方便一眼看出"你打开的是哪个版本"
  // （浏览器缓存是这类问题最常见的元凶，有这个号就不用猜了）
  const SITE_VERSION = "2026-10-12.2";

  /* ---------- 照片地址解析 ----------
     兼容两种来源：
       1) 仓库里的老照片，路径形如 photos/w001/1.jpg  → 直接用相对路径
       2) 新上传到 Supabase Storage 的照片，存的是对象路径
          形如 pending/<uid>/xxx.jpg 或 published/<wid>/1.jpg → 拼公开 URL
  */
  window.photoUrl = function (path) {
    if (!path) return "";
    if (/^https?:\/\//i.test(path)) return path;
    if (path.indexOf("photos/") === 0) return path;
    return cfg.SUPABASE_URL + "/storage/v1/object/public/" + cfg.PHOTO_BUCKET + "/" + path;
  };

  /* ---------- 缩略图地址 ----------
     约定：缩略图放在同目录的 thumb/ 子目录下
       photos/w001/1.jpg        → photos/w001/thumb/1.jpg      （仓库里的老照片）
       published/<wid>/1.jpg    → published/<wid>/thumb/1.jpg   （Supabase 里的新照片）
     找不到缩略图时浏览器会退回原图，所以这个函数是"尽力而为"。
  */
  window.thumbUrl = function (path) {
    if (!path) return "";
    const i = path.lastIndexOf("/");
    if (i < 0) return photoUrl(path);
    return photoUrl(path.slice(0, i) + "/thumb" + path.slice(i));
  };

  /* ---------- 登录态 ---------- */
  window.getSession = async function () {
    const { data } = await sb.auth.getSession();
    return data.session || null;
  };

  window.getProfile = async function (uid) {
    const { data, error } = await sb.from("profiles")
      .select("display_name, is_admin, status").eq("id", uid).maybeSingle();
    if (error) { console.warn("读取档案失败:", error.message); return null; }
    return data;
  };

  window.signOut = async function () {
    await sb.auth.signOut();
    location.href = "index.html";
  };

  /* ---------- 顶部导航 ----------
     页面里放 <div class="topbar" id="topbar"></div>，然后 renderTopbar('index')
  */
  window.renderTopbar = async function (active) {
    const el = document.getElementById("topbar");
    if (!el) return null;
    const fallback = function () {
      // 任何异常都退回到"只显示导航"，绝不让顶栏整块消失
      el.innerHTML =
        '<a class="brand" href="index.html">' + esc(cfg.SITE_TITLE) +
          '<span style="color:#9aa4b0;font-size:11px;font-weight:400;margin-left:7px">' +
          SITE_VERSION + "</span>" +
        "</a>" +
        '<nav class="nav"><a href="index.html">首页</a><a href="upload.html">上传</a>' +
        '<a class="btn small" href="login.html">登录</a></nav>';
      return { session: null, profile: null, isAdmin: false, failed: true };
    };
    try {
      const session = await getSession();
      let profile = null, isAdmin = false;
      if (session) {
        profile = await getProfile(session.user.id);
        isAdmin = !!(profile && profile.is_admin);
      }
      // 是否已通过注册审核（管理员天然通过）
      const approved = isAdmin || !!(profile && profile.status === "approved");
      const name = (profile && profile.display_name) || (session ? session.user.email : "");

      const links = [["index.html", "首页", "index"]];
      if (approved) links.push(["upload.html", "上传", "upload"]);
      if (session) links.push(["my.html", "我的投稿", "my"]);

      // 各种待处理计数
      let pendingWorks = 0, pendingReqs = 0, pendingMembers = 0;
      if (session) {
        try {
          const rq = await sb.from("photo_requests")
            .select("id", { count: "exact", head: true })
            .eq("status", "pending")
            .neq("requester", session.user.id);   // 自己的申请不用自己审
          pendingReqs = rq.count || 0;
        } catch (e) { console.warn("加照片申请计数失败:", e); }
      }
      if (isAdmin) {
        try {
          const c = await sb.from("works").select("id", { count: "exact", head: true }).eq("status", "pending");
          pendingWorks = c.count || 0;
        } catch (e) { console.warn("待审作品计数失败:", e); }
        try {
          const m = await sb.from("profiles").select("id", { count: "exact", head: true }).eq("status", "pending");
          pendingMembers = m.count || 0;
        } catch (e) { console.warn("待审成员计数失败:", e); }
        links.push(["review.html", "审核", "review"]);
        links.push(["members.html", "成员审核", "members"]);
      }
      if (pendingReqs > 0) links.push(["requests.html", "申请审核", "requests"]);

      const mkBadge = function (n) {
        return n > 0
          ? '<em style="font-style:normal;background:#d93025;color:#fff;border-radius:999px;' +
            'padding:0 6px;margin-left:5px;font-size:11.5px;line-height:17px;display:inline-block">' + n + "</em>"
          : "";
      };

      el.innerHTML =
        '<a class="brand" href="index.html">' + esc(cfg.SITE_TITLE) +
          '<span style="color:#9aa4b0;font-size:11px;font-weight:400;margin-left:7px">' +
          SITE_VERSION + "</span>" +
        "</a>" +
        '<nav class="nav">' +
          links.map(function (l) {
            let b = "";
            if (l[2] === "review") b = mkBadge(pendingWorks);
            if (l[2] === "requests") b = mkBadge(pendingReqs);
            if (l[2] === "members") b = mkBadge(pendingMembers);
            return '<a href="' + l[0] + '"' + (active === l[2] ? ' class="on"' : "") + ">" + l[1] + b + "</a>";
          }).join("") +
          (session
            ? '<span class="who" title="' + esc(session.user.email) + '">' + esc(name) +
              (isAdmin
                ? '<em class="tag">管理员</em>'
                : (approved ? "" : '<em class="tag" style="background:#fef7e0;color:#8a6d00">待审核</em>')) +
              "</span>" +
              '<button class="linkbtn" id="btnSignOut">退出</button>'
            : '<a class="btn small" href="login.html">登录</a>') +
        "</nav>";

      const out = document.getElementById("btnSignOut");
      if (out) out.onclick = function () { signOut(); };
      return { session: session, profile: profile, isAdmin: isAdmin, approved: approved };
    } catch (err) {
      console.error("renderTopbar 失败:", err);
      return fallback();
    }
  };

  /* ---------- 小工具 ---------- */
  window.esc = function (s) {
    return String(s == null ? "" : s)
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
  };

  // 把 Supabase 的英文报错翻译成能看懂的话
  window.zhError = function (msg) {
    const m = String(msg || "");
    const map = [
      [/Invalid login credentials/i, "邮箱或密码不对"],
      [/Email not confirmed/i, "邮箱还没验证——请先去收件箱点一下验证链接"],
      [/User already registered/i, "这个邮箱已经注册过了，直接登录就行"],
      [/Password should be at least (\d+)/i, "密码太短，至少要 $1 位"],
      [/Unable to validate email address/i, "邮箱格式不对"],
      [/For security purposes.*after (\d+) seconds/i, "操作太频繁了，请等 $1 秒再试"],
      [/rate limit|too many requests/i, "请求太频繁，请稍后再试"],
      [/Failed to fetch|NetworkError|Load failed/i, "网络连不上 Supabase（可能是网络问题或被拦）"],
      [/row-level security/i, "权限不足：这个操作被数据库规则拦下了"],
      [/duplicate key/i, "重复的数据，可能已经提交过了"]
    ];
    for (let i = 0; i < map.length; i++) {
      if (map[i][0].test(m)) return m.replace(map[i][0], map[i][1]);
    }
    return m || "未知错误";
  };

  // 带超时的请求包装：supabase-js 默认没有超时，网络一挂 Promise 永远不 settle
  window.withTimeout = function (promise, ms, label) {
    return Promise.race([
      promise,
      new Promise(function (_, rej) {
        setTimeout(function () {
          rej(new Error((label || "请求") + "超时（" + Math.round(ms / 1000) + " 秒），可能是网络卡住了"));
        }, ms);
      })
    ]);
  };

  // 简易提示条
  window.toast = function (msg, kind) {
    let t = document.getElementById("_toast");
    if (!t) {
      t = document.createElement("div");
      t.id = "_toast";
      t.className = "toast";
      document.body.appendChild(t);
    }
    t.textContent = msg;
    t.className = "toast show" + (kind ? " " + kind : "");
    clearTimeout(window._toastTimer);
    window._toastTimer = setTimeout(function () { t.className = "toast"; }, 3600);
  };
})();
