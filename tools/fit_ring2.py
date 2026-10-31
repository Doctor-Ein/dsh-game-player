"""fit_ring2.py - 精修：每个角度在半径区间里找最"青"的点，确定真实环半径与命中率。

输出：最优半径、环上 20 个采样点的颜色、以及"青色判据"的命中率。
用法：python fit_ring2.py qte-real.jpg
"""
import sys, io
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')

import numpy as np
from PIL import Image

path = sys.argv[1] if len(sys.argv) > 1 else 'qte-real.jpg'
img = Image.open(path).convert('RGB')
W, H = img.size
rgb = np.asarray(img, dtype=np.int32)

CX, CY = 0.6922 * W, 0.4993 * H

def cyan_score(c):
    # 越"青"分越高：G、B 高，R 低
    return (int(c[1]) + int(c[2])) - 2 * int(c[0])

def is_cyan(c):
    return c[1] >= 230 and c[2] >= 205 and c[0] <= 190

best = []
for deg in range(0, 360, 18):
    a = np.radians(deg)
    cand = []
    for rr in np.arange(48, 76, 1.0):
        x = int(round(CX + rr * np.cos(a)))
        y = int(round(CY + rr * np.sin(a)))
        if 0 <= x < W and 0 <= y < H:
            cand.append((cyan_score(rgb[y, x]), rr, rgb[y, x], x, y))
    cand.sort(key=lambda t: -t[0])
    s, rr, c, x, y = cand[0]
    best.append((deg, rr, c, is_cyan(c)))

radii = [b[1] for b in best]
print(f'angles=20  radius: median={np.median(radii):.1f}  min={min(radii):.1f}  max={max(radii):.1f}')
print(f'center px ({CX:.1f},{CY:.1f})  -> radius/height = {np.median(radii)/H:.4f}')

hits = sum(1 for b in best if b[3])
print(f'cyan hit rate at best radius: {hits}/20 = {hits/20*100:.0f}%')
print('\nper-angle best:')
for deg, rr, c, ok in best:
    mark = 'CYAN' if ok else '    '
    print(f'  {deg:3d}deg r={rr:4.1f}  RGB=({c[0]:3d},{c[1]:3d},{c[2]:3d})  {mark}')

# 同期对照：环外 1.6 倍半径（场景）的青色命中率
out_hits = 0
for deg in range(0, 360, 18):
    a = np.radians(deg)
    rr = float(np.median(radii)) * 1.6
    x = int(round(CX + rr * np.cos(a)))
    y = int(round(CY + rr * np.sin(a)))
    if 0 <= x < W and 0 <= y < H and is_cyan(rgb[y, x]):
        out_hits += 1
print(f'\ncontrol (r*1.6, scene): cyan hit {out_hits}/20')
