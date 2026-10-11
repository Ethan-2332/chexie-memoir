# 车协回忆录 · 网站

河海大学自行车协会骑行回忆录。目标形态：**不登录即可浏览和检索；登录后可上传**（上传是后续阶段）。

## 当前进度

| 阶段 | 状态 |
|---|---|
| 0 数据格式 + 本地原型 | ✅ **已完成** |
| 0 数据格式 + 本地原型 | ✅ **已完成** |
| 1 上线（免费托管） | ✅ 已推送 GitHub，**待开启 Pages** |
| 2 登录 + 上传（需后端） | ⬜ 待办 |
| 3 审核队列 | ⬜ 待办 |

**现在就能看**：双击 `docs\index.html`，浏览器里可以按日期、地名、关键词检索。

## 上线信息（2026-10-11）

| 项 | 值 |
|---|---|
| GitHub 仓库 | https://github.com/Ethan-2332/chexie-memoir （Public） |
| 首次推送 | `39ee2d3` 初版：骑行回忆录网站原型（19 个文件） |
| 计划网址 | https://ethan-2332.github.io/chexie-memoir/ |
| 网站目录 | `docs/`（GitHub Pages 认这个目录名，无需写 Actions 配置） |

**⚠️ 本机网络注意**：直连 `github.com` 不稳定（TLS 连接被重置），实测走本机代理可稳定推送。
本仓库已固化以下配置（**只影响这一个仓库**）：

```
git config --local http.proxy  http://127.0.0.1:7892
git config --local https.proxy http://127.0.0.1:7892
```

若代理软件关闭或换了端口，推送会失败。改端口：

```powershell
git config --local http.proxy  http://127.0.0.1:<新端口>
git config --local https.proxy http://127.0.0.1:<新端口>
```

**一条命令发布**（改完数据或加完照片后跑它）：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\publish.ps1
powershell -ExecutionPolicy Bypass -File scripts\publish.ps1 -Message "新增 3 张玄武湖照片"
```

它会自动完成：重新生成站点 → 暂存 → 提交 → 推送。

**手动发布**（等价于上面脚本的四步）：

```powershell
python scripts\build_site.py
git add -A
git commit -m "更新投稿数据"
git push
```

**开启 Pages 的路径**：仓库 → Settings → Pages → Source 选 `Deploy from a branch` →
Branch 选 `main`、目录选 `/docs` → Save。约 1 分钟后网址生效。

## 目录结构

```
车协回忆录-网站\
├─ data\posts.json        数据（唯一需要长期维护的资产）
├─ templates\index.html   页面模板（外观，含内联 CSS/JS）
├─ scripts\build_site.py  生成脚本
├─ docs\                  生成物，可随时删掉重建
│  ├─ index.html
│  ├─ posts.js
│  └─ photos\*.jpg
├─ 中间产物\              截图、临时文件
└─ README.md
```

## 怎么用

```powershell
# 重新生成（改完数据或模板后跑一次）
python scripts\build_site.py
```

- **加一条投稿**：编辑 `data\posts.json`，在 `posts` 数组里加一条，重跑脚本
- **改外观**：编辑 `templates\index.html`（样式和交互都在这一个文件里）
- **彻底重建**：删掉 `docs\` 目录再跑脚本

## 数据字段

| 字段 | 说明 |
|---|---|
| `id` | 唯一标识 |
| `date` | `YYYY-MM-DD`，**建议从照片 EXIF 自动读取** |
| `place` | 地名，搜索的主要维度 |
| `city` | 城市（预留：以后做地图） |
| `author` | 投稿人昵称，**不要填学号** |
| `caption` | 文案（投稿邮件的主题会写进这里） |
| `tags` | 标签数组，参与关键词搜索 |
| `photo` | 相对路径，如 `photos/p001.jpg` |
| `status` | `published` 显示 / `pending` 隐藏（**审核队列就是靠它**） |

## 已经为将来预留的设计

1. **数据与外观分离**：改样式只动 `templates/`，改内容只动 `data/posts.json`，将来加登录和上传不用返工。
2. **`status` 字段**：审核机制不用重做数据结构——上传的先进 `pending`，你点了通过才改成 `published`。
3. **占位图不覆盖**：`docs/photos/` 里已存在的文件不会被脚本覆盖，真实照片放进去就直接生效。
4. **输出转义**：页面渲染前对所有字段做 HTML 转义（`esc()`）。真实投稿内容是陌生人写的，不转义会形成 XSS 注入——这条从一开始就修好了。
5. **只输出 published**：`pending` 的条目留在数据里但不会出现在页面上。

## 说明

- 当前 12 条投稿与 12 张图片**全部是虚构的示例数据**，图片是按日期/地名生成的占位图，只为看效果。
- 底部声明（投稿即授权、下架联系方式、不显示学号）已写进 `data/posts.json` 的 `site.notice`，可随时改。
