"""gen_flag.py - 从主动 QTE（qte_flag）截图生成采样点模板。

和反击不同：
  · 环上的点少放（12 个，每 30°）
  · 重点放在中间的"拳头"轮廓（多放），因为拳头形状和反击的 >> 完全不同，
    这才是区分两种 QTE 的关键。
用法：python gen_flag.py qte-flag.png
"""
import sys, io
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')

import numpy as np
from PIL import Image

path = sys.argv[1] if len(sys.argv) > 1 else 'qte-flag.png'
img = Image.open(path).convert('RGB')
W, H = img.size
rgb = np.asarray(img, dtype=np.int32)
lum = rgb.mean(axis=2)
r_, g_, b_ = rgb[..., 0], rgb[..., 1], rgb[..., 2]


def pick(cx, cy, want, rad=3):
    best = None
    for dy in range(-rad, rad + 1):
        for dx in range(-rad, rad + 1):
            x, y = int(round(cx + dx)), int(round(cy + dy))
            if not (0 <= x < W and 0 <= y < H):
                continue
            c = rgb[y, x]
            d = sum(abs(int(c[i]) - want[i]) for i in range(3))
            if best is None or d < best[0]:
                best = (d, x, y, c)
    return best[1], best[2], best[3]


# ---- 1) 找青色，拟合圆心与半径
cyan = (b_ >= 200) & (g_ >= 170) & (r_ <= 170)
ys, xs = np.nonzero(cyan)
sel = (xs > W * 0.45) & (xs < W * 0.95) & (ys > H * 0.25) & (ys < H * 0.75)
xs, ys = xs[sel], ys[sel]
sys.stderr.write('cyan pixels in region: %d\n' % len(xs))
if len(xs) < 50:
    sys.exit('not enough cyan')
cx, cy = xs.mean(), ys.mean()
d = np.hypot(xs - cx, ys - cy)
R = np.median(d)
print('# center norm: (%.4f, %.4f)' % (cx / W, cy / H))
print('# radius px: %.1f  (= %.4f of height)' % (R, R / H))

points = []

# ---- 2) 环：12 个方向
for deg in range(0, 360, 30):
    a = np.radians(deg)
    best = None
    for rr in np.arange(R - 8, R + 9, 1.0):
        x, y = int(round(cx + rr * np.cos(a))), int(round(cy + rr * np.sin(a)))
        if not (0 <= x < W and 0 <= y < H):
            continue
        c = rgb[y, x]
        score = (int(c[1]) + int(c[2])) - 2 * int(c[0])
        if best is None or score > best[0]:
            best = (score, rr)
    rr = best[1]
    x, y, c = pick(cx + rr * np.cos(a), cy + rr * np.sin(a), (110, 240, 245))
    points.append(('ring', deg, (x - cx) / H, (y - cy) / H, int(c[0]), int(c[1]), int(c[2])))

# ---- 3) 拳头：在圆盘内部找亮像素，取轮廓上的点（不是中心）
yy, xx = np.mgrid[0:H, 0:W]
dist = np.hypot(xx - cx, yy - cy)
glyph = (dist < R * 0.62) & (lum > 170)
gy, gx = np.nonzero(glyph)
sys.stderr.write('glyph pixels: %d\n' % len(gx))
if len(gx) > 10:
    gx0, gx1, gy0, gy1 = int(gx.min()), int(gx.max()), int(gy.min()), int(gy.max())
    sys.stderr.write('glyph bbox: x %d..%d  y %d..%d\n' % (gx0, gx1, gy0, gy1))
    # 沿包围盒的边采 12 个点（轮廓）
    for deg in range(0, 360, 30):
        a = np.radians(deg)
        px = (gx0 + gx1) / 2 + ((gx1 - gx0) / 2) * np.cos(a)
        py = (gy0 + gy1) / 2 + ((gy1 - gy0) / 2) * np.sin(a)
        x, y, c = pick(px, py, (200, 240, 240), rad=2)
        if lum[y, x] > 120:
            points.append(('fist', deg, (x - cx) / H, (y - cy) / H, int(c[0]), int(c[1]), int(c[2])))

print('# pattern: 12 ring + %d fist' % (len(points) - 12))
print('$script:FlagPattern = @(')
for kind, deg, dx, dy, r, g, b in points:
    print('    @{{ dx = {0:.4f}; dy = {1:.4f}; r = {2}; g = {3}; b = {4} }}   # {5} {6}'.format(
        dx, dy, r, g, b, kind, deg))
print(')')
