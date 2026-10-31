"""fit_ring.py - 在真实反击 QTE 截图上拟合圆环：圆心、半径、环上颜色。

思路：找"青蓝色"像素（B 高、R 低），取它们的质心当圆心，半径用距离中位数。
输出：归一化圆心 + 半径（比例），以及环上 24 个方向的采样颜色。
用法：python fit_ring.py qte-real.jpg
"""
import sys, io
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')

import numpy as np
from PIL import Image

path = sys.argv[1] if len(sys.argv) > 1 else 'qte-real.jpg'
img = Image.open(path).convert('RGB')
W, H = img.size
rgb = np.asarray(img, dtype=np.int32)
r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]

# 青蓝：B 最强、G 中高、R 明显低
cyan = (b >= 200) & (g >= 170) & (r <= 170)
print(f'image {W}x{H}  cyan pixels: {int(cyan.sum())}')

ys, xs = np.nonzero(cyan)
if len(xs) < 50:
    print('too few cyan pixels; nothing found')
    sys.exit(0)

# 只保留画面中右部那一簇（排除别处的青色 UI）
sel = (xs > W * 0.45) & (xs < W * 0.95) & (ys > H * 0.25) & (ys < H * 0.75)
xs, ys = xs[sel], ys[sel]
print(f'cluster pixels: {len(xs)}')

cx, cy = xs.mean(), ys.mean()
d = np.hypot(xs - cx, ys - cy)
rad = np.median(d)
print(f'center px: ({cx:.1f},{cy:.1f})   radius px: {rad:.1f}')
print(f'center norm: ({cx/W:.4f},{cy/H:.4f})   radius norm: x={rad/W:.4f} y={rad/H:.4f}')

print('\nring samples (24 dirs, radius=r):')
cols = []
for deg in range(0, 360, 15):
    a = np.radians(deg)
    x = int(round(cx + rad * np.cos(a)))
    y = int(round(cy + rad * np.sin(a)))
    if 0 <= y < H and 0 <= x < W:
        c = rgb[y, x]
        cols.append((c[0], c[1], c[2]))
        print(f'  {deg:3d}deg ({x},{y}) RGB=({c[0]:3d},{c[1]:3d},{c[2]:3d})')

cols = np.array(cols)
print(f'\nmean RGB on ring: ({cols[:,0].mean():.0f},{cols[:,1].mean():.0f},{cols[:,2].mean():.0f})')
print(f'  R range {cols[:,0].min()}..{cols[:,0].max()}')
print(f'  G range {cols[:,1].min()}..{cols[:,1].max()}')
print(f'  B range {cols[:,2].min()}..{cols[:,2].max()}')

# 环内侧（黑盘）与外侧（场景）各采 8 点做对照
print('\ninner (0.45r) and outer (1.5r) controls:')
for label, k in (('inner', 0.45), ('outer', 1.5)):
    vals = []
    for deg in range(0, 360, 45):
        a = np.radians(deg)
        x = int(round(cx + rad * k * np.cos(a)))
        y = int(round(cy + rad * k * np.sin(a)))
        if 0 <= y < H and 0 <= x < W:
            vals.append(rgb[y, x])
    v = np.array(vals)
    print(f'  {label}: mean RGB ({v[:,0].mean():.0f},{v[:,1].mean():.0f},{v[:,2].mean():.0f})')
