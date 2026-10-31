# _counter-speed.ps1 - 测反击采样点判据的在线耗时
. "C:\Users\26338\Fairy\packages\dsh-game-player\lib\helper.ps1"

$g = @(Get-Windows '绝区零') | Where-Object { $_.title -eq '绝区零' } | Select-Object -First 1
if (-not $g) { "game window not found"; exit 1 }
$win = @{ x = $g.clientX; y = $g.clientY; w = $g.clientW; h = $g.clientH }
"window {0}x{1}" -f $win.w, $win.h

# 预热
$r = Test-CounterQte $win
"warmup: hit={0} ratio={1} ({2}/{3})" -f $r.hit, $r.ratio, $r.count, $r.total

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$n = 50
for ($i = 0; $i -lt $n; $i++) { [void](Test-CounterQte $win) }
$sw.Stop()
"Test-CounterQte x{0}: 总 {1} ms, 每次 {2:N2} ms" -f $n, $sw.ElapsedMilliseconds, ($sw.Elapsed.TotalMilliseconds / $n)
