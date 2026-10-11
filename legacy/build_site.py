"""把 data/posts.json + templates/index.html 生成为可双击打开的静态站点。

用法:
    python scripts/build_site.py

产物（全部在 docs/ 下，可随时删除重建）:
    docs/index.html    页面（数据已内联，file:// 直接打开即可用）
    docs/posts.js      数据副本（备用，便于以后拆分）
    docs/photos/*.jpg  示例占位图（真实照片就位后不会被覆盖）

目录名用 docs/ 是为了 GitHub Pages：仓库设置里选 "Deploy from a branch → main → /docs"
即可直接发布，不需要写任何 Actions 配置。

设计要点:
  * 数据与外观分离：改样式只动 templates/，改内容只动 data/posts.json。
  * 只输出 status=published 的条目；pending 的留在数据里等审核。
  * 占位图只在文件不存在时生成，真实照片放进来后不会被覆盖。
"""
import html
import json
import time
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data" / "posts.json"
TEMPLATE = ROOT / "templates" / "index.html"
SITE = ROOT / "docs"
PHOTOS = SITE / "photos"

FONT_CANDIDATES = [
    r"C:\Windows\Fonts\msyh.ttc",
    r"C:\Windows\Fonts\msyhbd.ttc",
    r"C:\Windows\Fonts\simhei.ttf",
    r"C:\Windows\Fonts\simsun.ttc",
]

PALETTES = [
    ((0x1b, 0x3a, 0x5c), (0x2e, 0x6f, 0x9e)),
    ((0x2d, 0x4a, 0x3f), (0x54, 0x8a, 0x6b)),
    ((0x5c, 0x3a, 0x2e), (0xa8, 0x6b, 0x4a)),
    ((0x3a, 0x2e, 0x5c), (0x6f, 0x5c, 0xa8)),
    ((0x4a, 0x4a, 0x4a), (0x8a, 0x8a, 0x8a)),
    ((0x5c, 0x2e, 0x45), (0xa8, 0x5c, 0x82)),
]


def load_font(size):
    for path in FONT_CANDIDATES:
        p = Path(path)
        if p.exists():
            try:
                return ImageFont.truetype(str(p), size)
            except Exception:
                continue
    return ImageFont.load_default()


def make_placeholder(path: Path, post: dict, index: int):
    """生成一张带渐变与文字的占位图（真实照片存在时不覆盖）。"""
    if path.exists():
        return False
    w, h = 1200, 900
    top, bottom = PALETTES[index % len(PALETTES)]
    img = Image.new("RGB", (w, h), top)
    draw = ImageDraw.Draw(img)
    for y in range(h):
        t = y / (h - 1)
        draw.line(
            [(0, y), (w, y)],
            fill=(
                int(top[0] + (bottom[0] - top[0]) * t),
                int(top[1] + (bottom[1] - top[1]) * t),
                int(top[2] + (bottom[2] - top[2]) * t),
            ),
        )
    f_big = load_font(96)
    f_mid = load_font(40)
    f_small = load_font(30)

    def center(text, font, y, fill):
        box = draw.textbbox((0, 0), text, font=font)
        draw.text(((w - (box[2] - box[0])) / 2 - box[0], y), text, font=font, fill=fill)

    center(post.get("place", ""), f_big, h // 2 - 150, (255, 255, 255))
    center(post.get("date", ""), f_mid, h // 2 + 10, (235, 240, 245))
    center("示例占位图 · 待替换为真实照片", f_small, h // 2 + 90, (215, 225, 235))
    center("@" + str(post.get("author", "")), f_small, h - 120, (225, 232, 240))
    path.parent.mkdir(parents=True, exist_ok=True)
    img.save(path, "JPEG", quality=82, optimize=True)
    return True


def main():
    data = json.loads(DATA.read_text(encoding="utf-8"))
    site_meta = data.get("site", {})
    posts = data.get("posts", [])
    published = [p for p in posts if (p.get("status") or "published") == "published"]

    SITE.mkdir(parents=True, exist_ok=True)
    PHOTOS.mkdir(parents=True, exist_ok=True)

    created = 0
    for i, p in enumerate(published):
        rel = p.get("photo") or f"photos/{p.get('id','p')}.jpg"
        p["photo"] = rel
        if make_placeholder(SITE / rel, p, i):
            created += 1

    payload = {"site": site_meta, "posts": published}
    (SITE / "posts.js").write_text(
        "const POSTS = " + json.dumps(payload, ensure_ascii=False, indent=2) + ";\n",
        encoding="utf-8",
    )

    tpl = TEMPLATE.read_text(encoding="utf-8")
    out = (tpl
           .replace("__TITLE__", html.escape(site_meta.get("title", "骑行回忆录")))
           .replace("__SUBTITLE__", html.escape(site_meta.get("subtitle", "")))
           .replace("__NOTICE__", html.escape(site_meta.get("notice", "")))
           .replace("__COUNT__", str(len(published)))
           .replace("__BUILD_TIME__", time.strftime("%Y-%m-%d %H:%M"))
           .replace("__POSTS_JSON__", json.dumps(payload, ensure_ascii=False)))
    (SITE / "index.html").write_text(out, encoding="utf-8")

    print("posts total   :", len(posts))
    print("published     :", len(published))
    print("pending(隐藏) :", len(posts) - len(published))
    print("占位图新生成  :", created)
    print("index.html    :", SITE / "index.html")
    print("size(bytes)   :", (SITE / "index.html").stat().st_size)


if __name__ == "__main__":
    main()
