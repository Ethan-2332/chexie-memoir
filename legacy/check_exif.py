"""检查原图里携带的元数据（隐私自查工具）。

发布照片前跑一次，看一眼你打算公开的照片里有没有：
  * 拍摄时间（一般无害）
  * GPS 精确坐标（会被读出拍摄地点，可能涉及隐私）
  * 相机/手机型号、序列号

用法：
    python scripts/check_exif.py
"""
import sys
from pathlib import Path

from PIL import Image, ExifTags

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "源文件" / "原图"
IMG_EXT = {".jpg", ".jpeg", ".png", ".webp", ".tif", ".tiff"}

INTERESTING = {
    "DateTimeOriginal": "拍摄时间",
    "Make": "相机厂商",
    "Model": "机型",
    "Software": "软件",
    "BodySerialNumber": "机身序列号",
    "LensSerialNumber": "镜头序列号",
    "Artist": "作者",
    "Copyright": "版权",
    "ImageDescription": "图像描述",
}


def to_deg(value, ref):
    try:
        d, m, s = float(value[0]), float(value[1]), float(value[2])
        dec = d + m / 60.0 + s / 3600.0
        if str(ref).upper() in ("S", "W"):
            dec = -dec
        return round(dec, 6)
    except Exception:
        return None


def main():
    if not SRC.exists():
        print("原图目录不存在:", SRC)
        return 0
    files = sorted(p for p in SRC.rglob("*") if p.is_file() and p.suffix.lower() in IMG_EXT)
    if not files:
        print("没有找到照片:", SRC)
        return 0

    gps_count = 0
    for p in files:
        rows = []
        lat = lon = None
        try:
            with Image.open(p) as im:
                ex = im.getexif()
                try:
                    sub = ex.get_ifd(ExifTags.IFD.Exif)
                    for k, v in sub.items():
                        name = ExifTags.TAGS.get(k, str(k))
                        if name in INTERESTING:
                            rows.append("%s=%s" % (INTERESTING[name], v))
                except Exception:
                    pass
                try:
                    gps = ex.get_ifd(ExifTags.IFD.GPSInfo)
                    if gps:
                        if gps.get(1) and gps.get(2):
                            lat = to_deg(gps[2], gps.get(1))
                        if gps.get(3) and gps.get(4):
                            lon = to_deg(gps[4], gps.get(3))
                except Exception:
                    pass
        except Exception as exc:
            rows.append("读取失败: %s" % exc)

        if lat is not None and lon is not None:
            gps_count += 1
            rows.append("GPS=%.6f, %.6f" % (lat, lon))

        kb = p.stat().st_size // 1024
        print("%-34s %6d KB  %s" % (p.name[:32], kb, " | ".join(rows) if rows else "（无元数据）"))

    print("-" * 90)
    print("照片总数: %d   含 GPS 定位的: %d" % (len(files), gps_count))
    if gps_count:
        print()
        print("⚠ 有 %d 张带 GPS 精确坐标。原图若上传到公开仓库/网站，任何人都能读出拍摄地点。" % gps_count)
        print("  发布用的网页图已在压缩时丢弃这些元数据，页面本身不会泄露。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
