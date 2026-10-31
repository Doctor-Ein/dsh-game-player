# _filmstrip.ps1 - 抓一段连续帧并拼成宫格（不经过手，也不需要游戏在前台）
param(
    [int]$Count = 32,
    [int]$IntervalMs = 250,
    [double]$Scale = 0.5,
    [string]$Out = "C:\Users\26338\Fairy\packages\dsh-game-player\tools\strip.png"
)

$ErrorActionPreference = 'Stop'
. "C:\Users\26338\Fairy\packages\dsh-game-player\lib\helper.ps1"

$game = @(Get-Windows '绝区零') | Where-Object { $_.title -eq '绝区零' } | Select-Object -First 1
if (-not $game) { "game window not found"; exit 1 }

# 先把 DSH 最小化，别挡住游戏
$dsh = @(Get-Windows $null) | Where-Object { $_.title -like '*DeepSeek Harness*' } | Select-Object -First 1
if ($dsh) { [void][Gp]::ShowWindow([IntPtr][int64]$dsh.hwnd, 6); Start-Sleep -Milliseconds 300 }

$dir = Join-Path $env:TEMP ("strip-" + (Get-Date -Format 'HHmmss'))
New-Item -ItemType Directory -Path $dir -Force | Out-Null

$t0 = [System.Diagnostics.Stopwatch]::StartNew()
for ($i = 0; $i -lt $Count; $i++) {
    $f = Capture-Frame $game.clientX $game.clientY $game.clientW $game.clientH $Scale
    $dst = Join-Path $dir ("frame{0:D3}.png" -f $i)
    Move-Item $f.path $dst -Force
    Start-Sleep -Milliseconds ([Math]::Max(0, $IntervalMs - 10))
}
"captured $Count frames in " + $t0.ElapsedMilliseconds + "ms"
"dir: $dir"

# 用 ffmpeg 拼宫格（8 列）
$ff = "C:\Users\26338\.dsh\tools\ffmpeg\bin\ffmpeg.exe"
$cols = 8
$rows = [Math]::Ceiling($Count / $cols)
& $ff -y -framerate 1 -i (Join-Path $dir 'frame%03d.png') -vf "tile=${cols}x${rows}:padding=4:color=black" -frames:v 1 $Out 2>&1 | Out-Null
"sheet: $Out  (" + [math]::Round((Get-Item $Out).Length/1KB) + "KB)"
