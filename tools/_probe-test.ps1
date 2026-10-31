# _probe-test.ps1 - 验证探针：能不能命中、单次要多久（决定轮询间隔能不能到 40ms）
. "C:\Users\26338\Fairy\packages\dsh-game-player\lib\helper.ps1"

# 用一个"整屏"的窗口矩形，模拟绑定后的坐标系
$w = [Gp]::GetSystemMetrics(0); $h = [Gp]::GetSystemMetrics(1)
$win = @{ x = 0; y = 0; w = $w; h = $h }
"screen ${w}x${h}"

# 1) 命名探针（qte 预设：右上区域找青色）
$r = Test-Probe 'qte' $win
"qte   hit={0} count={1} box={2},{3} {4}x{5}" -f $r.hit, $r.count, $r.box.x, $r.box.y, $r.box.w, $r.box.h

# 2) 白像素探针（桌面肯定有白）
$white = @{ probe = 'white'; region = @{ x = 0.40; y = 0.10; w = 0.20; h = 0.10 }; color = 'white'; minPixels = 50; stride = 3 }
$r2 = Test-Probe $white $win
"white hit={0} count={1} bbox={2}" -f $r2.hit, $r2.count, ($r2.bbox | ConvertTo-Json -Compress)

# 3) 计时：连续 10 次
$sw = [System.Diagnostics.Stopwatch]::StartNew()
for ($i = 0; $i -lt 10; $i++) { [void](Test-Probe 'qte' $win) }
$sw.Stop()
"10 probes in {0} ms  -> {1:N1} ms each" -f $sw.ElapsedMilliseconds, ($sw.Elapsed.TotalMilliseconds / 10)

# 4) 大步长版本
$qteFast = @{ probe = 'qte'; region = @{ x = 0.55; y = 0.02; w = 0.32; h = 0.30 }; color = 'cyan'; minPixels = 40; stride = 6 }
$sw.Restart()
for ($i = 0; $i -lt 10; $i++) { [void](Test-Probe $qteFast $win) }
$sw.Stop()
"stride6: {0:N1} ms each" -f ($sw.Elapsed.TotalMilliseconds / 10)
