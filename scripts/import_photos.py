"""真实照片导入工具（按「作品文件夹」组织）。

目录约定：
    源文件/原图/
    ├─ 2026.10.11天目湖-大溪水库/          ← 一个文件夹 = 一个作品
    │  ├─ xxx.jpg
    │  ├─ yyy.jpg
    │  └─ 说明.txt                        ← 可选
    ├─ 2024-05-18_玄武湖/                 ← 也可以
    └─ 2024-05-18_玄武湖_阿凯.jpg          ← 单张也行（一个文件 = 一个作品）

文件夹名 = 日期 + 地点，例如 2026.10.11天目湖-大溪水库
    日期认这些写法：2026.10.11 / 2026-10-11 / 2026_10_11 / 2026年10月11日 / 20261011
    地点 = 日期之后剩下的部分（自动去掉开头的 _ - . 空格）

说明.txt（可选，中文冒号/英文冒号都认，缺哪行就留空）：
    投稿人：阿凯
    文案：环湖一圈，风把汗都吹干了
    标签：环湖, 日落
    封面：xxx.jpg          ← 指定封面，默认取文件名排序第一张

用法：
    python scripts/import_photos.py --scan      # 只扫描并报告，不写任何文件
    python scripts/import_photos.py --import     # 生成网页图 + 更新 posts.json

产物：
    docs/photos/<作品id>/1.jpg            大图（长边 1600）
    docs/photos/<作品id>/thumb/1.jpg      缩略图（长边 600，列表用）
    data/posts.json                       站点数据（原示例数据会被替换）
    data/work-ids.json                   作品 id 映射（保证重复导入 id 不变）
"""
import argparse
import json
import re
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "源文件" / "原图"
POSTS = ROOT / "data" / "posts.json"
IDS = ROOT / "data" / "work-ids.json"
PHOTOS = ROOT / "docs" / "photos"

IMG_EXT = {".jpg", ".jpeg", ".png", ".webp", ".bmp", ".tif", ".tiff"}
SUSPECT_EXT = {".heic", ".heif", ".dng", ".cr2", ".nef", ".arw", ".raw"}
NOTE_NAMES = ("说明.txt", "info.txt", "说明.md", "readme.txt")
DATE_RE = re.compile(r"(\d{4})\s*[.\-_/年]\s*(\d{1,2})\s*[.\-_/月]\s*(\d{1,2})")
DATE_RE2 = re.compile(r"(?<!\d)(\d{4})(\d{2})(\d{2})(?!\d)")
KEY_AUTHOR = ("投稿人", "作者", "拍摄", "photo by", "by")
KEY_CAPTION = ("文案", "说明", "标题", "描述", "caption")
KEY_TAGS = ("标签", "tags")
KEY_COVER = ("封面", "cover")
KEY_DATE = ("日期", "date")
KEY_PLACE = ("地点", "位置", "place")


def natkey(p: Path):
    return [int(t) if t.isdigit() else t.lower() for t in re.split(r"(\d+)", p.name)]


def parse_name(text: str):
    """从文件夹名/文件名里解析出（日期, 地点）。"""
    date, rest = "", text
    m = DATE_RE.search(text)
    if m:
        date = f"{m.group(1)}-{int(m.group(2)):02d}-{int(m.group(3)):02d}"
        rest = text[:m.start()] + " " + text[m.end():]
    else:
        m2 = DATE_RE2.search(text)
        if m2:
            date = f"{m2.group(1)}-{m2.group(2)}-{m2.group(3)}"
            rest = text[:m2.start()] + " " + text[m2.end():]
    place = re.sub(r"^[\s_\-.,，、]+|[\s_\-.,，、]+$", "", rest)
    place = re.sub(r"\s+", " ", place).strip()
    return date, place


def parse_note(folder: Path):
    """读取说明文件。

    优先认固定名（说明.txt / info.txt …），其次认文件夹里**任意**一个 txt/md——
    这样随手「新建 文本文档.txt」也能被认出来，不必精确改名。
    空文件会被跳过，继续找下一个候选。
    """
    candidates = [folder / n for n in NOTE_NAMES]
    candidates += sorted(folder.glob("*.txt"))
    candidates += sorted(folder.glob("*.md"))
    seen = set()
    for p in candidates:
        if p in seen or not p.is_file():
            continue
        seen.add(p)
        try:
            text = p.read_text(encoding="utf-8-sig", errors="replace")
        except Exception:
            continue
        info = {}
        for line in text.splitlines():
            line = line.strip().lstrip("#").strip()
            if not line:
                continue
            for sep in ("：", ":"):
                if sep in line:
                    k, v = line.split(sep, 1)
                    info[k.strip().lower()] = v.strip()
                    break
        if info:
            return info
    return {}


def pick(info, keys, default=""):
    for k in keys:
        if k.lower() in info and info[k.lower()]:
            return info[k.lower()]
    return default


def write_scaled(src: Path, dst: Path, long_side: int, quality: int):
    dst.parent.mkdir(parents=True, exist_ok=True)
    with Image.open(src) as img:
        img = img.convert("RGB")
        w, h = img.size
        scale = long_side / float(max(w, h))
        if scale < 1:
            img = img.resize((max(1, int(w * scale)), max(1, int(h * scale))), Image.LANCZOS)
        img.save(dst, "JPEG", quality=quality, optimize=True, progressive=True)


def collect_works():
    """扫描原图目录，返回 [(来源名, 文件夹或None, [照片...]), ...]"""
    SRC.mkdir(parents=True, exist_ok=True)
    works, loose, bad = [], [], []
    for entry in sorted(SRC.iterdir(), key=natkey):
        if entry.is_dir():
            imgs = sorted([p for p in entry.rglob("*")
                           if p.is_file() and p.suffix.lower() in IMG_EXT], key=natkey)
            others = [p for p in entry.rglob("*")
                      if p.is_file() and p.suffix.lower() in SUSPECT_EXT]
            bad.extend(others)
            if imgs:
                works.append((entry.name, entry, imgs))
        elif entry.is_file():
            if entry.suffix.lower() in IMG_EXT:
                loose.append(entry)
            elif entry.suffix.lower() in SUSPECT_EXT:
                bad.append(entry)
    for p in loose:
        works.append((p.stem, None, [p]))
    return works, bad


def load_ids():
    if IDS.exists():
        try:
            return json.loads(IDS.read_text(encoding="utf-8"))
        except Exception:
            return {}
    return {}


def cmd_scan():
    works, bad = collect_works()
    if not works:
        print("原图目录里没有找到照片：", SRC)
        return 0
    print(f"{'来源':<34}{'日期':<12}{'地点':<20}{'张数':>4}  投稿人 / 文案")
    print("-" * 96)
    total = 0
    for name, folder, imgs in works:
        date, place = parse_name(name)
        info = parse_note(folder) if folder else {}
        date = pick(info, KEY_DATE, date)
        place = pick(info, KEY_PLACE, place)
        author = pick(info, KEY_AUTHOR)
        caption = pick(info, KEY_CAPTION)
        total += len(imgs)
        flag = "" if date and place else "  ⚠ 缺少" + ("日期" if not date else "") + ("地点" if not place else "")
        print(f"{name[:32]:<34}{date or '-':<12}{place[:18] or '-':<20}{len(imgs):>4}  {author or '-'} / {(caption or '-')[:28]}{flag}")
    print("-" * 96)
    print(f"作品数: {len(works)}   照片总数: {total}")
    if bad:
        print(f"\n⚠ 有 {len(bad)} 个文件格式不支持（HEIC 等），需要先转成 JPG：")
        for p in bad[:10]:
            print("    ", p.relative_to(SRC))
    print("\n确认无误后运行：python scripts/import_photos.py --import")
    return 0


def cmd_import():
    works, bad = collect_works()
    if not works:
        print("原图目录里没有找到照片：", SRC)
        return 1

    site_meta = {}
    if POSTS.exists():
        try:
            site_meta = json.loads(POSTS.read_text(encoding="utf-8")).get("site", {})
        except Exception:
            site_meta = {}

    ids = load_ids()
    used = set(ids.values())
    for name, _, _ in works:                     # 给新来源分配稳定的 id
        if name not in ids:
            i = 1
            while f"w{i:03d}" in used:
                i += 1
            ids[name] = f"w{i:03d}"
            used.add(ids[name])

    posts, problems = [], []
    for name, folder, imgs in works:
        date, place = parse_name(name)
        info = parse_note(folder) if folder else {}
        date = pick(info, KEY_DATE, date)
        place = pick(info, KEY_PLACE, place)
        author = pick(info, KEY_AUTHOR)
        caption = pick(info, KEY_CAPTION)
        tags = [t.strip() for t in re.split(r"[，,;；/]", pick(info, KEY_TAGS)) if t.strip()]
        cover = pick(info, KEY_COVER)

        if not date or not place:
            problems.append(f"{name}：缺{'日期' if not date else ''}{'地点' if not place else ''}，已跳过")
            continue

        wid = ids[name]
        outdir = PHOTOS / wid
        order = sorted(imgs, key=natkey)
        if cover:                                # 指定封面放到第一位
            order.sort(key=lambda p: (p.name != cover, natkey(p)))

        fulls, thumbs = [], []
        for n, src in enumerate(order, 1):
            try:
                write_scaled(src, outdir / f"{n}.jpg", 1600, 82)
                write_scaled(src, outdir / "thumb" / f"{n}.jpg", 600, 80)
            except Exception as exc:
                problems.append(f"{src.name}：处理失败 {exc}")
                continue
            fulls.append(f"photos/{wid}/{n}.jpg")
            thumbs.append(f"photos/{wid}/thumb/{n}.jpg")
        if not fulls:
            continue

        posts.append({
            "id": wid,
            "date": date,
            "place": place,
            "city": "",
            "author": author,
            "caption": caption,
            "tags": tags,
            "photo": fulls[0],          # 封面大图（兼容现有灯箱字段）
            "thumb": thumbs[0],         # 封面缩略图（列表用）
            "photos": fulls,            # 整组照片
            "thumbs": thumbs,
            "status": "published",
            "source": name,
        })

    IDS.write_text(json.dumps(ids, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    posts.sort(key=lambda p: (p["date"], p["place"]), reverse=True)
    POSTS.write_text(json.dumps({"site": site_meta, "posts": posts},
                                ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    print("作品数        :", len(posts))
    print("照片总数      :", sum(len(p["photos"]) for p in posts))
    print("网页图目录    :", PHOTOS)
    print("数据文件      :", POSTS)
    if problems:
        print("\n跳过/有问题：")
        for x in problems:
            print("   ", x)
    if bad:
        print(f"\n⚠ 不支持的格式 {len(bad)} 个（HEIC 等），未导入")
    print("\n下一步：python scripts/build_site.py  然后  powershell -File scripts/publish.ps1")
    return 0


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--scan", action="store_true")
    ap.add_argument("--import", dest="do_import", action="store_true")
    a = ap.parse_args()
    sys.exit(cmd_import() if a.do_import else cmd_scan())
