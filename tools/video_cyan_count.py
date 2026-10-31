"""video_cyan_count.py - 统计图标区域青色像素数随时间变化，找出 QTE 出现窗口。

不依赖模板：QTE 图标出现时，那块区域会突然多出一大团青色。
输出：青色数量超过阈值的连续时间窗。
用法：python video_cyan_count.py <video> [fps]
"""
import sys, io, re, subprocess
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')

import numpy as np

FFMPEG = r'C:\Users\26338\.dsh\tools\ffmpeg\bin\ffmpeg.exe'
video = sys.argv[1] if len(sys.argv) > 1 else r'C:\Users\26338\Videos\2026-11-01 04-28-56.mp4'
fps = float(sys.argv[2]) if len(sys.argv) > 2 else 10.0

probe = subprocess.run([FFMPEG, '-i', video], capture_output=True, text=True, errors='ignore')
m = re.search(r'(\d{2,5})x(\d{2,5})', probe.stderr)
w, h = int(m.group(1)), int(m.group(2))

# 图标可能出现的区域（归一化）
X0, X1 = 0.60, 0.80
Y0, Y1 = 0.38, 0.62
x0, x1 = int(w * X0), int(w * X1)
y0, y1 = int(h * Y0), int(h * Y1)

proc = subprocess.Popen(
    [FFMPEG, '-v', 'error', '-i', video, '-vf', f'fps={fps}', '-f', 'rawvideo',
     '-pix_fmt', 'rgb24', '-'], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
size = w * h * 3

series = []
i = 0
while True:
    buf = proc.stdout.read(size)
    if len(buf) < size:
        break
    f = np.frombuffer(buf, dtype=np.uint8).reshape((h, w, 3)).astype(np.int16)
    sub = f[y0:y1, x0:x1]
    r, g, b = sub[..., 0], sub[..., 1], sub[..., 2]
    cyan = (b >= 185) & (g >= 165) & (r <= 175) & ((g - r) >= 25)
    series.append((i / fps, int(cyan.sum())))
    i += 1
proc.stdout.close()
proc.wait()

vals = np.array([v for _, v in series])
base = np.median(vals)
mad = np.median(np.abs(vals - base)) + 1
thr = base + max(6 * mad, 400)
print(f'frames={len(series)}  region={x1-x0}x{y1-y0}  baseline={base:.0f}  mad={mad:.0f}  thr={thr:.0f}')
print(f'peak={vals.max()} @ {series[int(vals.argmax())][0]:.2f}s')

print('\nQTE windows (cyan spike):')
runs = []
cur = None
for t, v in series:
    on = v >= thr
    if on:
        if cur is None:
            cur = [t, t, v]
        else:
            cur[1] = t
            cur[2] = max(cur[2], v)
    else:
        if cur is not None:
            runs.append(cur)
            cur = None
if cur:
    runs.append(cur)
for a, b, peak in runs:
    print(f'  {a:6.2f} - {b:6.2f}   peak={peak:5d}   ({(b - a):.2f}s)')
