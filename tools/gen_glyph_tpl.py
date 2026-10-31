"""gen_glyph_tpl.py - 生成"内圈字形"模板（第 2 阶段分类用）。

流程：
  1) 用青色像素求圆心与半径（= 第 1 阶段检测到的环）
  2) 裁内部 0.62×半径 的方框（只看字形，不含外圈）
  3) 缩到 48×48 灰度，存为 tpl2-counter.png / tpl2-flag.png
"""
import sys, io
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')

import numpy as np
from PIL import Image

SIZE = 48
INNER = 0.62

REFS = [('counter', 'qte-real.jpg'), ('flag', 'qte-flag.png')]


def ring_frame(path):
    rgb = np.asarray(Image.open(path).convert('RGB'), dtype=np.int32)
    H, W = rgb.shape[:2]
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    m = (b >= 185) & (g >= 165) & (r <= 175)
    ys, xs = np.nonzero(m)
    keep = (xs > W * 0.40) & (xs < W * 0.95) & (ys > H * 0.20) & (ys < H * 0.85)
    xs, ys = xs[keep], ys[keep]
    cx, cy = xs.mean(), ys.mean()
    d = np.hypot(xs - cx, ys - cy)
    return cx, cy, float(np.median(d))


def glyph_patch(path, cx, cy, rad):
    im = Image.open(path).convert('L')
    half = rad * INNER
    box = (int(cx - half), int(cy - half), int(cx + half), int(cy + half))
    p = np.asarray(im.crop(box).resize((SIZE, SIZE), Image.BOX), dtype=np.float64)
    return p


def norm(a):
    return (a - a.mean()) / (a.std() + 1e-6)


patches = {}
for name, path in REFS:
    cx, cy, rad = ring_frame(path)
    p = glyph_patch(path, cx, cy, rad)
    patches[name] = norm(p)
    out = np.clip(p, 0, 255).astype(np.uint8)
    Image.fromarray(out).save(f'tpl2-{name}.png')
    print(f'tpl2-{name}.png  ring c=({cx:.0f},{cy:.0f}) r={rad:.1f}  inner=0.62')

print('\nNCC:')
for a in patches:
    for b in patches:
        print(f'  {a:8s} vs {b:8s} = {float((patches[a]*patches[b]).mean()):+.2f}')
