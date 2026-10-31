# _qte-speed.ps1 - 测 C# 圆环检测的真实耗时（决定能不能 40ms 轮询）
. "C:\Users\26338\Fairy\packages\dsh-game-player\lib\helper.ps1"

$w = [Gp]::GetSystemMetrics(0); $h = [Gp]::GetSystemMetrics(1)
$win = @{ x = 0; y = 0; w = $w; h = $h }
"screen ${w}x${h}"

# 预热一次（首次会触发 JIT / 位图分配）
$r = Test-QteRing $win
"warmup: hit={0} count={1}" -f $r.hit, $r.count

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$n = 20
for ($i = 0; $i -lt $n; $i++) { [void](Test-QteRing $win) }
$sw.Stop()
"Test-QteRing x{0}: 总 {1} ms, 每次 {2:N1} ms" -f $n, $sw.ElapsedMilliseconds, ($sw.Elapsed.TotalMilliseconds / $n)

# 再单独量"采集"和"扫描"两段
$bmp = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$sw.Restart()
for ($i = 0; $i -lt $n; $i++) { $g.CopyFromScreen(0, 0, 0, 0, (New-Object System.Drawing.Size($w, $h))) }
$sw.Stop()
"CopyFromScreen x{0}: 每次 {1:N1} ms" -f $n, ($sw.Elapsed.TotalMilliseconds / $n)
$g.Dispose()

$shot = Get-BitmapBytes $bmp
$sw.Restart()
for ($i = 0; $i -lt $n; $i++) { [void][Gp]::ScanQte($shot.bytes, $shot.w, $shot.h, $shot.stride) }
$sw.Stop()
"ScanQte x{0}: 每次 {1:N1} ms" -f $n, ($sw.Elapsed.TotalMilliseconds / $n)
$bmp.Dispose()
