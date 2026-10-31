# _press-f1.ps1 - 把游戏提到前台、按一下 F1、再截图，看活动界面会不会出来。
. "C:\Users\26338\Fairy\packages\dsh-game-player\lib\helper.ps1"

$game = @(Get-Windows $null) | Where-Object { $_.title -eq '绝区零' } | Select-Object -First 1
if (-not $game) { "游戏窗口没找到"; exit 1 }

$h = [IntPtr][int64]$game.hwnd
"game: hwnd={0} pid={1} {2}x{3}" -f $game.hwnd, $game.pid, $game.clientW, $game.clientH

# 还原 + 提到最前（不是最小化 DSH，只是让游戏压在上面）
[void][Gp]::ShowWindow($h, 9)
Start-Sleep -Milliseconds 150
[void][Gp]::SetForegroundWindow($h)
Start-Sleep -Milliseconds 400

$info = Get-WindowInfo $h
"foreground=" + $info.foreground

# F1 = 0x70。按 80ms，比 60ms 稳一点。
[Gp]::KeySend([uint16]0x70, $false)
Start-Sleep -Milliseconds 80
[Gp]::KeySend([uint16]0x70, $true)
"F1 sent"

Start-Sleep -Milliseconds 900
$shot = Capture-Frame $info.clientX $info.clientY $info.clientW $info.clientH 0.5
"shot: {0} ({1}x{2})" -f $shot.path, $shot.w, $shot.h
