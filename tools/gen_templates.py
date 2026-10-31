"""gen_templates.py - 从参考截图生成 48x48 灰度模板，并做跨分辨率验证。

参考图（2560x1440）：qte-real.jpg（反击 >>）、qte-flag.png（主动 拳头）
验证图（1920x1080 录像帧）：ic-1880.png（反击）、v29.png（主动）
用法：python gen_templates.py
"""
import sys, io
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')

import numpy as np
from PIL import Image

SIZE = 48
K = 2.6

# name, path, cx_norm, cy_norm, ring_r_norm(=r / frame_height)
REFS = [
    ('counter', 'qte-real.jpg', 0.6922, 0.4993, 65.0 / 1440),
    ('flag',    'qte-flag.png', 0.6823, 0.5099, 54.0 / 1440),
]

# 验证用的"没见过的"帧（1080p）
CHECKS = [
    ('video-counter', 'ic-1880.png', 0.6922, 0.4993),
    ('video-flag',    'v29.png',     0.6823, 0.5099),
]


def patch_from(img_l, cx_n, cy_n, r_n):
    """按"环半径的 K 倍"裁方框，缩到 SIZE x SIZE，返回归一化灰度。"""
    W, H = img_l.size
    cx, cy = cx_n * W, cy_n * H
    half = r_n * H * K / 2.0
    box = (int(round(cx - half)), int(round(cy - half)),
           int(round(cx + half)), int(round(cy + half)))
    p = img_l.crop(box).resize((SIZE, SIZE), Image.BOX)
    a = np.asarray(p, dtype=np.float64)
    return (a - a.mean()) / (a.std() + 1e-6)


def ncc(a, b):
    return float((a * b).mean())


tpls = {}
for name, path, cx, cy, r in REFS:
    img = Image.open(path).convert('L')
    t = patch_from(img, cx, cy, r)
    tpls[name] = t
    out = Image.fromarray(np.clip((t - t.min()) / (t.max() - t.min()) * 255, 0, 255).astype(np.uint8))
    out.save(f'tpl-{name}.png')
    print(f'template saved: tpl-{name}.png')

print('\nNCC matrix (same-resolution):')
for a in tpls:
    print('  ' + a.ljust(8) + '  '.join(f'{ncc(tpls[a], tpls[b]):+.2f}' for b in tpls))

print('\ncross-resolution check (1080p video frames):')
for label, path, cx, cy in CHECKS:
    img = Image.open(path).convert('L')
    print(f'  {label}:')
    for name, _, _, _, r in REFS:
        obs = patch_from(img, cx, cy, r)
        print(f'    vs tpl-{name:8s} NCC = {ncc(obs, tpls[name]):+.2f}')
