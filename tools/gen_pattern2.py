"""gen_pattern2.py - 从真实反击 QTE 截图生成采样点模板。

每个点 = 相对圆心的偏移（以画面高度为单位）+ 期望 RGB。
两组点：环 20 个（青色）、中间 >> 若干（亮色箭头，自动找）。
用法：python gen_pattern2.py qte-real.jpg
"""
import sys, io
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')

import numpy as np
from PIL import Image

path = sys.argv[1] if len(sys.argv) > 1 else 'qte-real.jpg'
img = Image.open(path).convert('RGB')
W, H = img.size
rgb = np.asarray(img, dtype=np.int32)
lum = rgb.mean(axis=2)

CX, CY = 0.6922 * W, 0.4993 * H
R = 65.0


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


points = []

for deg in range(0, 360, 18):
    a = np.radians(deg)
    best = None
    for rr in np.arange(58, 73, 1.0):
        x, y = int(round(CX + rr * np.cos(a))), int(round(CY + rr * np.sin(a)))
        if not (0 <= x < W and 0 <= y < H):
            continue
        c = rgb[y, x]
        score = (int(c[1]) + int(c[2])) - 2 * int(c[0])
        if best is None or score > best[0]:
            best = (score, rr)
    rr = best[1]
    x, y, c = pick(CX + rr * np.cos(a), CY + rr * np.sin(a), (118, 252, 243))
    points.append(('ring', deg, (x - CX) / H, (y - CY) / H, int(c[0]), int(c[1]), int(c[2])))

yy, xx = np.mgrid[0:H, 0:W]
inner = (np.hypot(xx - CX, yy - CY) < R * 0.62) & (lum > 195)
gy, gx = np.nonzero(inner)
sys.stderr.write('glyph pixels: %d\n' % len(gx))
if len(gx) > 10:
    gx0, gx1 = int(gx.min()), int(gx.max())
    gy0, gy1 = int(gy.min()), int(gy.max())
    sys.stderr.write('glyph bbox px: x %d..%d y %d..%d\n' % (gx0, gx1, gy0, gy1))
    for fx in (0.15, 0.5, 0.85):
        for fy in (0.15, 0.85):
            px = gx0 + (gx1 - gx0) * fx
            py = gy0 + (gy1 - gy0) * fy
            x, y, c = pick(px, py, (240, 240, 235), rad=2)
            if int(c[0]) + int(c[1]) + int(c[2]) > 430:
                points.append(('chev', 0, (x - CX) / H, (y - CY) / H, int(c[0]), int(c[1]), int(c[2])))

print('# generated from ' + path)
print('# dx/dy are fractions of frame height, relative to the ring centre')
print('# ring points: 20, chevron points: %d' % (len(points) - 20))
print('$script:CounterPattern = @(')
for kind, deg, dx, dy, r, g, b in points:
    print('    @{{ dx = {0:.4f}; dy = {1:.4f}; r = {2}; g = {3}; b = {4} }}   # {5} {6}'.format(
        dx, dy, r, g, b, kind, ('%ddeg' % deg) if kind == 'ring' else ''))
print(')')
