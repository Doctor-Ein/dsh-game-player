"""calibrate_qte.py - QTE 离线标定：在一组帧上算候选特征的分离度。

不做识别，只回答一个问题：**哪些特征在 QTE 帧和非 QTE 帧之间拉得开？**

用法：
    python calibrate_qte.py qteframe-001250.png qteframe-001251.png --neg qteframe-001247.png

输出：每帧的特征值 + 青蓝色连通块的包围盒（按画面比例）。
依赖：numpy + Pillow（随 DSH 打包的 python 里有）。
"""

import sys, io
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')
from pathlib import Path

import numpy as np
from PIL import Image

# 分析用的降采样尺寸：480x270 足够看出一个 120px 的圆环，扫描又够快
WORK_W, WORK_H = 480, 270

# 青蓝色（QTE 圆环）在 HSV 里的范围。S 和 V 都放开一点，
# 因为不同场景下环的亮度会变，但"色相偏青 + 够亮"很稳定。
CYAN_HUE = (168, 196)      # 实测圆环 H 落在 174..186
CYAN_SAT_MIN = 0.10
CYAN_VAL_MIN = 0.88       # 实测 V 251..255，卡高一点排掉白字


def load_full(path: Path) -> np.ndarray:
    """全分辨率读入。**不要在阈值之前缩放**：QTE 圆环只有约 7px 宽，
    先把 1920 缩到 480，等于把亮环和暗背景平均掉，V 掉到 0.6 以下就再也检不出来了。
    正确顺序是：全分辨率判阈值 -> 再合并（这里用 4x4 max-pool）。"""
    img = Image.open(path).convert("RGB")
    return np.asarray(img, dtype=np.float32) / 255.0


def pool_mask(mask: np.ndarray) -> np.ndarray:
    """把全分辨率布尔掩码按 4x4 合并成 480x270：块内只要有一个命中就算命中。"""
    h, w = mask.shape
    ph, pw = h // 4, w // 4
    m = mask[: ph * 4, : pw * 4].reshape(ph, 4, pw, 4).any(axis=(1, 3))
    return m


def rgb_to_hsv(rgb: np.ndarray) -> np.ndarray:
    """rgb: HxWx3 in 0..1 -> HxWx3 (h in 0..255, s 0..1, v 0..1)"""
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    mx = rgb.max(axis=-1)
    mn = rgb.min(axis=-1)
    diff = mx - mn + 1e-6
    h = np.zeros_like(mx)
    mask = mx == r
    h[mask] = ((g - b) / diff)[mask] % 6
    mask = mx == g
    h[mask] = ((b - r) / diff + 2)[mask]
    mask = mx == b
    h[mask] = ((r - g) / diff + 4)[mask]
    h = h * 60.0          # 统一成"度"（0..360），和采样脚本、CYAN_HUE 一个口径
    s = diff / (mx + 1e-6)
    return np.stack([h, s, mx], axis=-1)


def cyan_mask(hsv: np.ndarray, rgb: np.ndarray) -> np.ndarray:
    """只认"近白青"：实测圆环 RGB≈(185,253,255)。
    普通青色（天空、能量条）红通道低得多，用 R>=0.60 一道门槛就能把环境切掉。"""
    h, s, v = hsv[..., 0], hsv[..., 1], hsv[..., 2]
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    return (
        (h >= CYAN_HUE[0]) & (h <= CYAN_HUE[1])
        & (s >= CYAN_SAT_MIN) & (v >= CYAN_VAL_MIN)
        & (r >= 0.60) & (g >= 0.90) & (b >= 0.90)
    )


def label_blobs(mask: np.ndarray, min_area: int = 12):
    """四邻域连通块。纯 numpy + 栈，够用（480x270 上掩码很稀疏）。"""
    seen = np.zeros_like(mask, dtype=bool)
    blobs = []
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
                blobs.append({
                    "area": len(pts),
                    "x0": min(xs), "x1": max(xs),
                    "y0": min(ys), "y1": max(ys),
                })
    blobs.sort(key=lambda b: -b["area"])
    return blobs


def features(path: Path) -> dict:
    rgb = load_full(path)
    hsv = rgb_to_hsv(rgb)
    mask_full = cyan_mask(hsv, rgb)
    mask = pool_mask(mask_full)
    blobs = label_blobs(mask)
    v = hsv[..., 2]

    # 形状判据（实测：QTE 环 fill≈0.13 / aspect≈1.18 / area≈120；
    # 天空块 fill 0.45+ / aspect 2.9+ / area 2800+）。颜色切不掉环境，形状可以。
    ring_candidates = []
    for bl in blobs:
        bw = bl["x1"] - bl["x0"] + 1
        bh = bl["y1"] - bl["y0"] + 1
        if bw <= 0 or bh <= 0:
            continue
        fill = bl["area"] / float(bw * bh)
        aspect = bw / float(bh)
        cy_norm = (bl["y0"] + bl["y1"]) / 2.0 / WORK_H
        # 排除角色脚下的青色目标环（实测在 y≈0.88）。QTE 环出现在画面中部。
        if not (0.12 <= cy_norm <= 0.72):
            continue
        if 0.6 <= aspect <= 1.7 and 0.05 <= fill <= 0.28 and 50 <= bl["area"] <= 800:
            ring_candidates.append({"x0": bl["x0"], "x1": bl["x1"], "y0": bl["y0"], "y1": bl["y1"],
                                    "area": bl["area"], "fill": fill, "aspect": aspect})
    ring_candidates.sort(key=lambda b: -b["area"])
    top = ring_candidates[0] if ring_candidates else None
    extra = {"ring_candidates": len(ring_candidates)}
    ring = None
    if top:
        bw = top["x1"] - top["x0"] + 1
        bh = top["y1"] - top["y0"] + 1
        fill = top["area"] / float(bw * bh)          # 环的填充率远低于实心块
        ring = {
            "cx": (top["x0"] + top["x1"]) / 2 / WORK_W,
            "cy": (top["y0"] + top["y1"]) / 2 / WORK_H,
            "w": bw / WORK_W, "h": bh / WORK_H,
            "aspect": bw / float(bh),
            "fill": fill,
            "area": top["area"],
        }

    return {
        "name": path.name,
        "cyan_px": int(mask.sum()),
        "cyan_ratio": round(float(mask.mean()) * 100, 3),
        "blobs": len(blobs),
        "brightness": round(float(v.mean()) * 255, 1),
        "top_ring": ring, **extra,
    }


def main(argv):
    args = argv[1:]
    neg = []
    if "--neg" in args:
        i = args.index("--neg")
        neg = [Path(p) for p in args[i + 1:]]
        args = args[:i]
    pos = [Path(p) for p in args]
    if not pos:
        print(__doc__)
        return 2

    print(f"{'frame':<24}{'bright':>8}{'cyan%':>8}{'blobs':>7}   最大青蓝块 (cx,cy,w,h) / aspect / fill")
    print("-" * 96)
    for group, files in (("QTE", pos), ("对照", neg)):
        for f in files:
            r = features(f)
            ring = r["top_ring"]
            desc = "-"
            if ring:
                desc = (f"({ring['cx']:.2f},{ring['cy']:.2f} {ring['w']:.3f}x{ring['h']:.3f})"
                        f" a={ring['aspect']:.2f} fill={ring['fill']:.2f} area={ring['area']}")
            print(f"[{group}] {r['name']:<18}{r['brightness']:>8}{r['cyan_ratio']:>8}"
                  f"{r['blobs']:>7}   {desc}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
