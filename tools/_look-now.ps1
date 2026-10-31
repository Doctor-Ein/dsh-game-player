# _look-now.ps1 - 抓一张"真的那个游戏"的画面（按标题全等挑窗口，避免抓成 DSH 自己）
. "C:\Users\26338\Fairy\packages\dsh-game-player\lib\helper.ps1"

$all = @(Get-Windows $null)
"candidates with 绝区零:"
$all | Where-Object { $_.title -like '*绝区零*' } | ForEach-Object { "  hwnd={0} pid={1} {2}x{3} :: {4}" -f $_.hwnd, $_.pid, $_.clientW, $_.clientH, $_.title }

$game = $all | Where-Object { $_.title -eq '绝区零' } | Select-Object -First 1
if (-not $game) { $game = $all | Where-Object { $_.title -like '*绝区零*' } | Sort-Object clientW -Descending | Select-Object -First 1 }
if (-not $game) { "没找到游戏窗口"; exit 1 }

"picked: hwnd={0} pid={1} {2}x{3} at {4},{5}" -f $game.hwnd, $game.pid, $game.clientW, $game.clientH, $game.clientX, $game.clientY
$shot = Capture-Frame $game.clientX $game.clientY $game.clientW $game.clientH 0.5
"shot: {0} ({1}x{2})" -f $shot.path, $shot.w, $shot.h
