"""radial.py - 比较两个 QTE 图标的径向颜色分布，找出能区分它们的位置。

对每张图，以图标圆心为中心，逐半径统计"青色点"占该圈的比例。
用法：python radial.py qte-real.jpg qte-flag.png
"""
import sys, io
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')

import numpy as np
from PIL import Image

specs = [
    ('counter/qte-real.jpg', 'qte-real.jpg', 0.6922, 0.4993),
    ('flag/qte-flag.png', 'qte-flag.png', 0.6823, 0.5099),
]


def is_cyan(c):
    return c[1] >= 200 and c[2] >= 200 and c[0] <= 175


rows = {}
for name, path, nx, ny in specs:
    img = Image.open(path).convert('RGB')
    W, H = img.size
    rgb = np.asarray(img, dtype=np.int32)
    cx, cy = nx * W, ny * H
    prof = []
    for r in range(10, 96, 2):
        hit = 0
        tot = 0
        for deg in range(0, 360, 10):
            a = np.radians(deg)
            x, y = int(round(cx + r * np.cos(a))), int(round(cy + r * np.sin(a)))
            if 0 <= x < W and 0 <= y < H:
                tot += 1
                if is_cyan(rgb[y, x]):
                    hit += 1
        prof.append((r, hit / max(1, tot)))
    rows[name] = prof

print('radius  counter  flag')
for i, (r, v) in enumerate(rows['counter/qte-real.jpg']):
    fv = rows['flag/qte-flag.png'][i][1]
    bar_c = '#' * int(v * 30)
    bar_f = '#' * int(fv * 30)
    flag = ''
    if abs(v - fv) >= 0.5:
        flag = '  <-- 区分!'
    print(f'{r:5d}   {v:4.2f}    {fv:4.2f}   {bar_c:<30}|{bar_f:<30}{flag}')
