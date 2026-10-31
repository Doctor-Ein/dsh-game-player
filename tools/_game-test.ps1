# _game-test.ps1 - 对真实游戏窗口：找到 → 聚焦 → 截客户区 → 回一张图
. "C:\Users\26338\Fairy\packages\dsh-game-player\lib\helper.ps1"

$ws = @(Get-Windows '绝区零')
if ($ws.Count -eq 0) { "游戏窗口没找到"; exit 1 }
$w = $ws[0]
"found: hwnd={0} pid={1} client={2}x{3} at {4},{5} min={6} fg={7}" -f $w.hwnd, $w.pid, $w.clientW, $w.clientH, $w.clientX, $w.clientY, $w.minimized, $w.foreground

[void][Gp]::ShowWindow([IntPtr][int64]$w.hwnd, 9)
[void][Gp]::SetForegroundWindow([IntPtr][int64]$w.hwnd)
Start-Sleep -Milliseconds 250

$info = Get-WindowInfo ([IntPtr][int64]$w.hwnd)
"after focus: foreground={0}" -f $info.foreground

$shot = Capture-Frame $info.clientX $info.clientY $info.clientW $info.clientH 0.5
"shot: {0} ({1}x{2})" -f $shot.path, $shot.w, $shot.h

$sheet = Build-Sheet @($shot.path) 2 640 @('1  client area')
"sheet: {0} ({1}x{2})" -f $sheet.path, $sheet.w, $sheet.h
