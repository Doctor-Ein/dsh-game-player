"""qte_detect.py - QTE 空心圆环检测器（离线标定/回归用）。

思路（全部传统 CV，无第三方库）：
    近白青阈值 -> 4x4 合并 -> 连通块 -> 几何三数 -> 径向检验

在 480x270 的合并网格上算，跟将来 C# 里的实现一一对应。

用法：
    # 单帧/几帧对比
    python qte_detect.py --frames a.png b.png --neg c.png

    # 扫一段视频（rawvideo 管道，不落盘）
    python qte_detect.py --video X.mp4 --from 12:40 --to 13:00 --fps 5 --sheet hits.png
"""

import sys
import io
import subprocess
import tempfile
from pathlib import Path

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8")

import numpy as np
from PIL import Image, ImageDraw

FFMPEG = r"C:\Users\26338\.dsh\tools\ffmpeg\bin\ffmpeg.exe"

GRID_W, GRID_H = 480, 270        # 合并后的网格

# ---- 颜色：实测圆环 RGB≈(185,253,255)，沙漠天空也是近白青，所以颜色只做粗筛
HUE_MIN, HUE_MAX = 168.0, 196.0
SAT_MIN = 0.10
VAL_MIN = 0.88
R_MIN, G_MIN, B_MIN = 0.60, 0.90, 0.90

# ---- 形状：实测 QTE 环 fill≈0.13 aspect≈1.18 area≈117；天空 fill 0.45+ aspect 2.9+
SHAPE_ASPECT = (0.6, 1.7)
SHAPE_FILL = (0.05, 0.28)
SHAPE_AREA = (50, 800)
BAND_Y = (0.12, 0.72)


def hsv_deg(rgb):
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    mx = rgb.max(axis=-1)
    mn = rgb.min(axis=-1)
    d = mx - mn + 1e-9
    h = np.zeros_like(mx)
    m = mx == r
    h[m] = ((g - b) / d)[m] % 6
    m = mx == g
    h[m] = ((b - r) / d + 2)[m]
    m = mx == b
    h[m] = ((r - g) / d + 4)[m]
    return h * 60.0, d / (mx + 1e-9), mx


def pale_cyan_mask(rgb):
    h, s, v = hsv_deg(rgb)
    return (
        (h >= HUE_MIN) & (h <= HUE_MAX)
        & (s >= SAT_MIN) & (v >= VAL_MIN)
        & (rgb[..., 0] >= R_MIN) & (rgb[..., 1] >= G_MIN) & (rgb[..., 2] >= B_MIN)
    )


def pool4(mask):
    h, w = mask.shape
    ph, pw = h // 4, w // 4
    return mask[: ph * 4, : pw * 4].reshape(ph, 4, pw, 4).any(axis=(1, 3))


def blobs(mask, min_area=50):
    seen = np.zeros_like(mask, dtype=bool)
    out = []
    h, w = mask.shape
    for y0 in range(h):
        for x0 in range(w):
            if not mask[y0, x0] or seen[y0, x0]:
                continue
            stack = [(y0, x0)]
            seen[y0, x0] = True
            pts = []
            while stack:
                y, x = stack.pop()
                pts.append((y, x))
                for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    ny, nx = y + dy, x + dx
                    if 0 <= ny < h and 0 <= nx < w and mask[ny, nx] and not seen[ny, nx]:
                        seen[ny, nx] = True
                        stack.append((ny, nx))
            if len(pts) >= min_area:
                ys = [p[0] for p in pts]
                xs = [p[1] for p in pts]
                out.append({"area": len(pts), "x0": min(xs), "x1": max(xs), "y0": min(ys), "y1": max(ys)})
    out.sort(key=lambda b: -b["area"])
    return out


def radial(mask, blob):
    """径向检验：环带上应该几乎全是命中，圆心和更外侧应该是空的。
    这一条才是"空心圆环"的直接证据。"""
    cx = (blob["x0"] + blob["x1"]) / 2.0
    cy = (blob["y0"] + blob["y1"]) / 2.0
    r = max(blob["x1"] - blob["x0"], blob["y1"] - blob["y0"]) / 2.0
    if r < 2:
        return None
    h, w = mask.shape
    band_hit = band_n = core_hit = core_n = out_hit = out_n = 0
    for deg in range(0, 360, 5):
        a = np.radians(deg)
        for rr, bucket in ((0.80, "band"), (0.92, "band"), (1.02, "band"),
                           (0.20, "core"), (0.40, "core"),
                           (1.25, "out"), (1.45, "out")):
            x = int(round(cx + r * rr * np.cos(a)))
            y = int(round(cy + r * rr * np.sin(a)))
            inside = 0 <= y < h and 0 <= x < w
            hit = bool(mask[y, x]) if inside else False
            if bucket == "band":
                band_n += 1; band_hit += hit
            elif bucket == "core":
                core_n += 1; core_hit += hit
            else:
                out_n += 1; out_hit += hit
    return {
        "band": band_hit / max(1, band_n),
        "core": core_hit / max(1, core_n),
        "out": out_hit / max(1, out_n),
    }


def detect(rgb):
    """返回 {hit, rings:[...], cyan_ratio}。rgb: HxWx3 float 0..1，全分辨率。"""
    mask_full = pale_cyan_mask(rgb)
    mask = pool4(mask_full)
    rings = []
    for bl in blobs(mask):
        bw = bl["x1"] - bl["x0"] + 1
        bh = bl["y1"] - bl["y0"] + 1
        if bw <= 0 or bh <= 0 or bl["area"] > SHAPE_AREA[1]:
            continue
        fill = bl["area"] / float(bw * bh)
        aspect = bw / float(bh)
        cy = (bl["y0"] + bl["y1"]) / 2.0 / GRID_H
        if not (BAND_Y[0] <= cy <= BAND_Y[1]):
            continue
        if not (SHAPE_ASPECT[0] <= aspect <= SHAPE_ASPECT[1]):
            continue
        if not (SHAPE_FILL[0] <= fill <= SHAPE_FILL[1]):
            continue
        if not (SHAPE_AREA[0] <= bl["area"] <= SHAPE_AREA[1]):
            continue
        rad = radial(mask, bl)
        if not rad:
            continue
        rings.append({
            "cx": (bl["x0"] + bl["x1"]) / 2.0 / GRID_W,
            "cy": cy,
            "w": bw / GRID_W,
            "h": bh / GRID_H,
            "area": bl["area"], "fill": fill, "aspect": aspect,
            "band": rad["band"], "core": rad["core"], "out": rad["out"],
        })
    return {"hit": bool(rings), "rings": rings,
            "cyan_ratio": float(mask.mean()) * 100}


def probe_size(video):
    """用 ffprobe 拿分辨率；rawvideo 流本身不带帧头。"""
    ffprobe = FFMPEG.replace("ffmpeg.exe", "ffprobe.exe")
    out = subprocess.run(
        [ffprobe, "-v", "error", "-select_streams", "v:0",
         "-show_entries", "stream=width,height", "-of", "csv=p=0", video],
        capture_output=True, text=True).stdout.strip()
    w, h = [int(x) for x in out.split(",")[:2]]
    return w, h


def read_frames(video, t0, t1, fps):
    """ffmpeg 出 rawvideo rgb24，直接读，不落盘。"""
    w, h = probe_size(video)
    dur = max(0.04, t1 - t0)
    cmd = [FFMPEG, "-v", "error", "-ss", str(t0), "-t", str(dur), "-i", video,
           "-vf", f"fps={fps}", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    frame_bytes = w * h * 3
    try:
        while True:
            buf = proc.stdout.read(frame_bytes)
            if len(buf) < frame_bytes:
                break
            yield w, h, np.frombuffer(buf, np.uint8).reshape(h, w, 3).astype(np.float32) / 255.0
    finally:
        proc.stdout.close()
        proc.wait()


def parse_hms(s):
    parts = [float(p) for p in s.split(":")]
    while len(parts) < 3:
        parts.insert(0, 0.0)
    return parts[0] * 3600 + parts[1] * 60 + parts[2]


def main(argv):
    args = argv[1:]
    if not args:
        print(__doc__)
        return 2

    if "--frames" in args:
        i = args.index("--frames")
        j = args.index("--neg") if "--neg" in args else len(args)
        pos = [Path(p) for p in args[i + 1:j]]
        neg = [Path(p) for p in args[j + 1:]] if j < len(args) else []
        print(f"{'frame':<26}{'hit':>5}{'cyan%':>8}   ring")
        print("-" * 92)
        for tag, group in (("QTE", pos), ("NEG", neg)):
            for p in group:
                rgb = np.asarray(Image.open(p).convert("RGB"), dtype=np.float32) / 255.0
                r = detect(rgb)
                ring = r["rings"][0] if r["rings"] else None
                desc = "-"
                if ring:
                    desc = (f"({ring['cx']:.2f},{ring['cy']:.2f}) a={ring['aspect']:.2f} "
                            f"fill={ring['fill']:.2f} area={ring['area']} "
                            f"band={ring['band']:.2f} core={ring['core']:.2f} out={ring['out']:.2f}")
                print(f"[{tag}] {p.name:<20}{'YES' if r['hit'] else '.':>5}{r['cyan_ratio']:>8.2f}   {desc}")
        return 0

    if "--video" in args:
        video = args[args.index("--video") + 1]
        t0 = parse_hms(args[args.index("--from") + 1]) if "--from" in args else 0.0
        t1 = parse_hms(args[args.index("--to") + 1]) if "--to" in args else t0 + 30
        fps = float(args[args.index("--fps") + 1]) if "--fps" in args else 5.0
        sheet = args[args.index("--sheet") + 1] if "--sheet" in args else None

        n = hits = 0
        hit_times = []
        thumbs = []
        for w, h, rgb in read_frames(video, t0, t1, fps):
            t = t0 + n / fps
            n += 1
            r = detect(rgb)
            if r["hit"]:
                hits += 1
                ring = r["rings"][0]
                hit_times.append((t, ring))
                print(f"  HIT  {t:7.2f}s  ({ring['cx']:.2f},{ring['cy']:.2f}) "
                      f"a={ring['aspect']:.2f} fill={ring['fill']:.2f} area={ring['area']} "
                      f"band={ring['band']:.2f} core={ring['core']:.2f} out={ring['out']:.2f}")
                if sheet:
                    small = Image.fromarray((rgb * 255).astype(np.uint8)).resize((384, 216))
                    d = ImageDraw.Draw(small)
                    bx = ring["cx"] * 384
                    by = ring["cy"] * 216
                    rr = max(ring["w"], ring["h"]) * 384
                    d.ellipse([bx - rr, by - rr, bx + rr, by + rr], outline=(255, 0, 0), width=2)
                    d.text((4, 4), f"{t:.1f}s", fill=(255, 255, 0))
                    thumbs.append(small)

        print(f"\n扫了 {n} 帧（{fps}fps），命中 {hits} 帧，命中率 {100.0*hits/max(1,n):.2f}%")
        if sheet and thumbs:
            cols = 4
            rows = (len(thumbs) + cols - 1) // cols
            sh = Image.new("RGB", (cols * 384, rows * 216), (20, 20, 24))
            for i, th in enumerate(thumbs[:cols * rows]):
                sh.paste(th, ((i % cols) * 384, (i // cols) * 216))
            sh.save(sheet)
            print(f"宫格已存: {sheet}")
        return 0

    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
