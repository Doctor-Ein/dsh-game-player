"""tpl_check.py - 验证"用字形模板能不能把两种 QTE 分开"。

做法：从两张参考图各裁出图标区（以图标中心为准，取 2.6×环半径的方框），
缩放到 48x48 灰度，两两算归一化互相关（NCC）。对角线应该高、非对角应该低。
如果分不开，就说明还得加上"外圈"这一层特征。
"""
import sys, io
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')

import numpy as np
from PIL import Image

REF = [
    ('counter', 'qte-real.jpg', 0.6922, 0.4993, 65.0),
    ('flag',    'qte-flag.png', 0.6823, 0.5099, 54.0),
]
SIZE = 48
K = 2.6          # 方框边长 = K × 环半径


def patch(path, nx, ny, ring_r):
    img = Image.open(path).convert('L')
    W, H = img.size
    cx, cy = nx * W, ny * H
    half = ring_r * K / 2
    box = (cx - half, cy - half, cx + half, cy + half)
    p = img.crop(tuple(int(round(v)) for v in box)).resize((SIZE, SIZE), Image.BILINEAR)
    a = np.asarray(p, dtype=np.float64)
    a = (a - a.mean()) / (a.std() + 1e-6)
    return a


def ncc(a, b):
    return float((a * b).mean())


tpl = {}
for name, path, nx, ny, r in REF:
    tpl[name] = patch(path, nx, ny, r)

print('patch stats:')
for k, v in tpl.items():
    print(f'  {k:8s} mean={v.mean():+.2f} std={v.std():.2f}')

print('\nNCC matrix (rows = 参考图, cols = 模板):')
print('           counter     flag')
for ra in tpl:
    row = []
    for rb in tpl:
        row.append(ncc(tpl[ra], tpl[rb]))
    print(f'  {ra:8s}  ' + '   '.join(f'{v:+.2f}' for v in row))

# 加一点扰动，看稳定性（模拟录像压缩/轻微偏移）
print('\nrobustness: 加噪声 + 平移 1px 后自己对自己的 NCC')
rng = np.random.default_rng(0)
for name, a in tpl.items():
    noisy = a + rng.normal(0, 0.15, a.shape)
    noisy = (noisy - noisy.mean()) / (noisy.std() + 1e-6)
    shifted = np.roll(np.roll(a, 1, axis=0), 1, axis=1)
    print(f'  {name:8s} noise={ncc(a, noisy):+.2f}  shift1px={ncc(a, shifted):+.2f}')
