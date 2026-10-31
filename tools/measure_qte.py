"""measure_qte.py - 在一张全屏截图上量 QTE 图标的真实位置与颜色。

只做离线分析：找"黄绿色括角"像素（这个颜色在场景里极少见），输出包围盒与比例。
用法：python measure_qte.py qte-ref.jpg
"""
import sys, io
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')

import numpy as np
from PIL import Image

path = sys.argv[1] if len(sys.argv) > 1 else 'qte-ref.jpg'
img = Image.open(path).convert('RGB')
W, H = img.size
print(f'image {W}x{H}')

rgb = np.asarray(img, dtype=np.int32)
r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]

# 黄绿（lime）：绿最强、蓝很低、红中高
lime = (g >= 190) & (r >= 140) & (r <= 230) & (b <= 130)
print('lime pixels:', int(lime.sum()))

ys, xs = np.nonzero(lime)
if len(xs) == 0:
    print('no lime found')
    sys.exit(0)

# 只用最大的那一簇附近：先按行聚类，找像素最密的区域
# 简单做法：取所有 lime 点的中位数中心，再取 ±400px 内的点
cx0, cy0 = int(np.median(xs)), int(np.median(ys))
print(f'lime median center: ({cx0},{cy0}) -> norm ({cx0/W:.3f},{cy0/H:.3f})')

near = (np.abs(xs - cx0) < 500) & (np.abs(ys - cy0) < 400)
xs2, ys2 = xs[near], ys[near]
x0, x1 = int(xs2.min()), int(xs2.max())
y0, y1 = int(ys2.min()), int(ys2.max())
print(f'lime bbox px: x {x0}..{x1}  y {y0}..{y1}   ({x1-x0+1}x{y1-y0+1})')
print(f'lime bbox norm: x0={x0/W:.4f} x1={x1/W:.4f}  y0={y0/H:.4f} y1={y1/H:.4f}')
print(f'  center norm: ({((x0+x1)/2)/W:.4f}, {((y0+y1)/2)/H:.4f})')

# 建议的搜索框：四周各留 60% 余量（图标可能轻微移动）
mx = (x1 - x0 + 1) * 0.6
my = (y1 - y0 + 1) * 0.6
sx0 = max(0, int(x0 - mx)); sx1 = min(W - 1, int(x1 + mx))
sy0 = max(0, int(y0 - my)); sy1 = min(H - 1, int(y1 + my))
print(f'suggested search box norm: x {sx0/W:.4f}..{sx1/W:.4f}  y {sy0/H:.4f}..{sy1/H:.4f}')

# 图标内部：黑盘 + 白 chevron
sub = rgb[y0:y1+1, x0:x1+1]
lum = sub.mean(axis=2)
print(f'inside bbox luminance: min={lum.min():.0f} mean={lum.mean():.0f} max={lum.max():.0f}')
print(f'  dark(<40) ratio={float((lum<40).mean())*100:.1f}%  bright(>200)={float((lum>200).mean())*100:.1f}%')

# 采样几个 lime 像素的真实值
idx = np.linspace(0, len(xs2) - 1, 6).astype(int)
print('sample lime colors:')
for i in idx:
    x, y = xs2[i], ys2[i]
    print(f'  ({x},{y}) RGB=({rgb[y,x,0]},{rgb[y,x,1]},{rgb[y,x,2]})')
