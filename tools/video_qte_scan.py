"""video_qte_scan.py - 用两个采样点模板扫描视频，输出 QTE 时间线。

不依赖 trace：直接看录像里图标什么时候是青色、什么时候变灰。
两种模板同时计算，能直接看出"同一帧是否被两种同时匹配"（混用）。
用法：python video_qte_scan.py <video> [fps]
"""
import sys, io, subprocess
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')

import numpy as np

FFMPEG = r'C:\Users\26338\.dsh\tools\ffmpeg\bin\ffmpeg.exe'
video = sys.argv[1] if len(sys.argv) > 1 else r'C:\Users\26338\Videos\2026-11-01 04-28-56.mp4'
fps = float(sys.argv[2]) if len(sys.argv) > 2 else 6.0

# 与引擎里一致的模板（dx/dy 以画面高度为单位）
COUNTER_C = (0.6922, 0.4993)
COUNTER = [(0.0423, -0.0007), (0.0423, 0.0111), (0.0368, 0.0236), (0.0278, 0.0354),
           (0.0125, 0.0431), (0.0000, 0.0451), (-0.0139, 0.0444), (-0.0257, 0.0382),
           (-0.0382, 0.0278), (-0.0445, 0.0153), (-0.0472, -0.0014), (-0.0431, -0.0160),
           (-0.0375, -0.0292), (-0.0264, -0.0375), (-0.0146, -0.0417), (-0.0014, -0.0451),
           (0.0118, -0.0424), (0.0257, -0.0361), (0.0354, -0.0243), (0.0423, -0.0146),
           (-0.0146, -0.0146), (-0.0167, 0.0160), (0.0034, -0.0167), (0.0021, 0.0160),
           (0.0201, -0.0146), (0.0194, 0.0132)]
COUNTER_RGB = [(122, 252, 242), (121, 253, 242), (120, 255, 240), (119, 250, 244),
               (119, 255, 244), (126, 252, 241), (118, 253, 239), (118, 252, 245),
               (121, 255, 242), (118, 254, 240), (121, 250, 245), (116, 253, 243),
               (118, 252, 241), (117, 250, 245), (117, 252, 246), (118, 249, 243),
               (118, 255, 247), (118, 252, 245), (116, 253, 243), (118, 252, 243),
               (125, 249, 241), (131, 250, 246), (133, 213, 204), (158, 244, 233),
               (139, 246, 238), (143, 244, 236)]

FLAG_C = (0.6823, 0.5099)
FLAG = [(0.0384, -0.0023), (0.0266, 0.0137), (0.0182, 0.0338), (0.0023, 0.0304),
        (-0.0207, 0.0373), (-0.0359, 0.0200), (-0.0380, -0.0002), (-0.0262, -0.0141),
        (-0.0193, -0.0363), (-0.0019, -0.0328), (0.0175, -0.0328), (0.0300, -0.0196),
        (0.0238, 0.0005), (0.0189, 0.0116), (0.0106, 0.0200), (0.0023, 0.0200),
        (-0.0207, 0.0109), (-0.0109, -0.0189), (0.0009, -0.0224), (0.0120, -0.0217),
        (0.0196, -0.0134)]
FLAG_RGB = [(111, 239, 246), (114, 242, 245), (121, 249, 250), (124, 245, 247),
            (122, 226, 255), (128, 223, 250), (149, 221, 251), (120, 240, 249),
            (111, 238, 254), (106, 234, 248), (107, 235, 248), (109, 237, 247),
            (112, 239, 246), (114, 241, 246), (116, 243, 246), (128, 223, 226),
            (124, 241, 246), (116, 231, 242), (108, 236, 247), (108, 237, 247),
            (120, 226, 235)]

TOL = 70

# 取视频尺寸
probe = subprocess.run([FFMPEG, '-i', video], capture_output=True, text=True, errors='ignore')
w = h = 0
import re
m = re.search(r'(\d{2,5})x(\d{2,5})', probe.stderr)
if m:
    w, h = int(m.group(1)), int(m.group(2))
print(f'video {w}x{h}  fps={fps}')

proc = subprocess.Popen(
    [FFMPEG, '-v', 'error', '-i', video, '-vf', f'fps={fps}', '-f', 'rawvideo',
     '-pix_fmt', 'rgb24', '-'],
    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
size = w * h * 3


def ratio(frame, center, pts, rgbs):
    cx, cy = center[0] * w, center[1] * h
    hit = 0
    for (dx, dy), (er, eg, eb) in zip(pts, rgbs):
        x = int(round(cx + dx * h))
        y = int(round(cy + dy * h))
        if 0 <= x < w and 0 <= y < h:
            c = frame[y, x]
            if abs(int(c[0]) - er) + abs(int(c[1]) - eg) + abs(int(c[2]) - eb) <= TOL:
                hit += 1
    return hit / len(pts)


idx = 0
rows = []
while True:
    buf = proc.stdout.read(size)
    if len(buf) < size:
        break
    frame = np.frombuffer(buf, dtype=np.uint8).reshape((h, w, 3))
    rc = ratio(frame, COUNTER_C, COUNTER, COUNTER_RGB)
    rf = ratio(frame, FLAG_C, FLAG, FLAG_RGB)
    rows.append((idx / fps, rc, rf))
    idx += 1
proc.stdout.close()
proc.wait()
print(f'frames scanned: {len(rows)}')

print('\n time   counter  flag   state')
runs = []
cur = None
for t, rc, rf in rows:
    c_on = rc >= 0.8
    f_on = rf >= 0.8
    state = 'both' if (c_on and f_on) else ('counter' if c_on else ('flag' if f_on else '-'))
    if state != cur:
        runs.append([state, t, t])
        cur = state
    else:
        runs[-1][2] = t

for state, a, b in runs:
    if state == '-':
        continue
    print(f'{a:6.2f} - {b:6.2f}  {state.upper():8s}  ({b - a:.2f}s)')

top_c = sorted(rows, key=lambda r: -r[1])[:6]
top_f = sorted(rows, key=lambda r: -r[2])[:6]
print('\n TOP counter: ' + ', '.join(f'{t:.2f}s={r:.2f}' for t, r, _ in top_c))
print(' TOP flag   : ' + ', '.join(f'{t:.2f}s={r:.2f}' for t, _, r in top_f))

print('\nworst mixed frames (both ratios high):')
for t, rc, rf in rows:
    if rc >= 0.6 and rf >= 0.6:
        print(f'  t={t:6.2f}  counter={rc:.2f} flag={rf:.2f}')
