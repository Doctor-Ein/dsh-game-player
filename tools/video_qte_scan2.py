"""video_qte_scan2.py - 带位置容差地扫描视频里的 QTE。

对每帧：在 ±12px 范围内搜索最佳偏移（步长 3），取两个模板的最高命中比例。
这样即使图标位置偏一点也能认出来。输出 QTE 时间线（类型 + 起止 + 峰值）。
用法：python video_qte_scan2.py <video> [fps]
"""
import sys, io, re, subprocess
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')

import numpy as np

FFMPEG = r'C:\Users\26338\.dsh\tools\ffmpeg\bin\ffmpeg.exe'
video = sys.argv[1] if len(sys.argv) > 1 else r'C:\Users\26338\Videos\2026-11-01 04-28-56.mp4'
fps = float(sys.argv[2]) if len(sys.argv) > 2 else 6.0

COUNTER_C = (0.6922, 0.4993)
FLAG_C = (0.6823, 0.5099)

COUNTER = [(0.0423, -0.0007), (0.0423, 0.0111), (0.0368, 0.0236), (0.0278, 0.0354),
           (0.0125, 0.0431), (0.0000, 0.0451), (-0.0139, 0.0444), (-0.0257, 0.0382),
           (-0.0382, 0.0278), (-0.0445, 0.0153), (-0.0472, -0.0014), (-0.0431, -0.0160),
           (-0.0375, -0.0292), (-0.0264, -0.0375), (-0.0146, -0.0417), (-0.0014, -0.0451),
           (0.0118, -0.0424), (0.0257, -0.0361), (0.0354, -0.0243), (0.0423, -0.0146),
           (-0.0146, -0.0146), (-0.0167, 0.0160), (0.0034, -0.0167), (0.0021, 0.0160),
           (0.0201, -0.0146), (0.0194, 0.0132)]
COUNTER_RGB = np.array([(122, 252, 242), (121, 253, 242), (120, 255, 240), (119, 250, 244),
                        (119, 255, 244), (126, 252, 241), (118, 253, 239), (118, 252, 245),
                        (121, 255, 242), (118, 254, 240), (121, 250, 245), (116, 253, 243),
                        (118, 252, 241), (117, 250, 245), (117, 252, 246), (118, 249, 243),
                        (118, 255, 247), (118, 252, 245), (116, 253, 243), (118, 252, 243),
                        (125, 249, 241), (131, 250, 246), (133, 213, 204), (158, 244, 233),
                        (139, 246, 238), (143, 244, 236)], dtype=np.int32)

FLAG = [(0.0384, -0.0023), (0.0266, 0.0137), (0.0182, 0.0338), (0.0023, 0.0304),
        (-0.0207, 0.0373), (-0.0359, 0.0200), (-0.0380, -0.0002), (-0.0262, -0.0141),
        (-0.0193, -0.0363), (-0.0019, -0.0328), (0.0175, -0.0328), (0.0300, -0.0196),
        (0.0238, 0.0005), (0.0189, 0.0116), (0.0106, 0.0200), (0.0023, 0.0200),
        (-0.0207, 0.0109), (-0.0109, -0.0189), (0.0009, -0.0224), (0.0120, -0.0217),
        (0.0196, -0.0134)]
FLAG_RGB = np.array([(111, 239, 246), (114, 242, 245), (121, 249, 250), (124, 245, 247),
                     (122, 226, 255), (128, 223, 250), (149, 221, 251), (120, 240, 249),
                     (111, 238, 254), (106, 234, 248), (107, 235, 248), (109, 237, 247),
                     (112, 239, 246), (114, 241, 246), (116, 243, 246), (128, 223, 226),
                     (124, 241, 246), (116, 231, 242), (108, 236, 247), (108, 237, 247),
                     (120, 226, 235)], dtype=np.int32)

TOL = 70
OFFS = range(-12, 13, 3)

probe = subprocess.run([FFMPEG, '-i', video], capture_output=True, text=True, errors='ignore')
m = re.search(r'(\d{2,5})x(\d{2,5})', probe.stderr)
w, h = int(m.group(1)), int(m.group(2))

proc = subprocess.Popen(
    [FFMPEG, '-v', 'error', '-i', video, '-vf', f'fps={fps}', '-f', 'rawvideo',
     '-pix_fmt', 'rgb24', '-'], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
size = w * h * 3


def best_ratio(frame, center, pts, rgbs):
    cx, cy = center[0] * w, center[1] * h
    best = 0.0
    for ox in OFFS:
        for oy in OFFS:
            hit = 0
            for (dx, dy), e in zip(pts, rgbs):
                x = int(round(cx + dx * h + ox))
                y = int(round(cy + dy * h + oy))
                if 0 <= x < w and 0 <= y < h:
                    c = frame[y, x]
                    if abs(int(c[0]) - e[0]) + abs(int(c[1]) - e[1]) + abs(int(c[2]) - e[2]) <= TOL:
                        hit += 1
            r = hit / len(pts)
            if r > best:
                best = r
    return best


rows = []
i = 0
while True:
    buf = proc.stdout.read(size)
    if len(buf) < size:
        break
    frame = np.frombuffer(buf, dtype=np.uint8).reshape((h, w, 3))
    rc = best_ratio(frame, COUNTER_C, COUNTER, COUNTER_RGB)
    rf = best_ratio(frame, FLAG_C, FLAG, FLAG_RGB)
    rows.append((i / fps, rc, rf))
    i += 1
proc.stdout.close()
proc.wait()
print(f'frames {len(rows)}  video {w}x{h}')

print('\n time  counter  flag   verdict')
runs = []
cur = None
for t, rc, rf in rows:
    c_on, f_on = rc >= 0.8, rf >= 0.8
    if c_on and f_on:
        st = 'BOTH'
    elif c_on:
        st = 'counter'
    elif f_on:
        st = 'flag'
    else:
        st = '-'
    if st != cur:
        runs.append([st, t, t, max(rc, rf)])
        cur = st
    else:
        runs[-1][2] = t
        runs[-1][3] = max(runs[-1][3], max(rc, rf))

for st, a, b, peak in runs:
    if st == '-':
        continue
    print(f'{a:6.2f} - {b:6.2f}  {st:8s} peak={peak:.2f}  ({b - a:5.2f}s)')

if rows:
    bc = max(rows, key=lambda x: x[1])
    bf = max(rows, key=lambda x: x[2])
    print('\npeaks: counter %.2f @ %.2fs   flag %.2f @ %.2fs' % (bc[1], bc[0], bf[2], bf[0]))
