"""_sample_ring.py - 在 QTE 帧上采样圆环的真实颜色，用来定 HSV 范围。"""
import sys
from pathlib import Path
import numpy as np
from PIL import Image

def hsv_of(rgb):
    r, g, b = rgb
    mx, mn = max(rgb), min(rgb)
    diff = mx - mn
    if diff == 0:
        h = 0.0
    elif mx == r:
        h = (60 * ((g - b) / diff)) % 360
    elif mx == g:
        h = 60 * ((b - r) / diff) + 120
    else:
        h = 60 * ((r - g) / diff) + 240
    s = 0 if mx == 0 else diff / mx
    return h, s, mx

path = Path(sys.argv[1])
cx, cy, r = int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
img = np.asarray(Image.open(path).convert("RGB"), dtype=np.int32)

samples = []
for ang in range(0, 360, 6):
    for rad in (r - 3, r - 1, r + 1, r + 3):
        x = cx + int(rad * np.cos(np.radians(ang)))
        y = cy + int(rad * np.sin(np.radians(ang)))
        if 0 <= y < img.shape[0] and 0 <= x < img.shape[1]:
            samples.append((x, y, img[y, x]))

print(f"{path.name}  center=({cx},{cy}) r={r}  samples={len(samples)}")

# 找最亮的那些像素（环本身应该是最亮的青蓝）
bright = sorted(samples, key=lambda s: -(int(s[2][0]) + int(s[2][1]) + int(s[2][2])))[:24]
print("\n最亮的 24 个环上像素：")
hs = []
for x, y, c in bright:
    h, s, v = hsv_of(c)
    hs.append((h, s, v))
    print(f"  ({x},{y})  RGB=({c[0]:3d},{c[1]:3d},{c[2]:3d})  H={h:6.1f} S={s:.2f} V={v:.2f}")

hs = np.array(hs)
print(f"\nH 范围 {hs[:,0].min():.0f}..{hs[:,0].max():.0f}  "
      f"S 范围 {hs[:,1].min():.2f}..{hs[:,1].max():.2f}  "
      f"V 范围 {hs[:,2].min():.2f}..{hs[:,2].max():.2f}")
