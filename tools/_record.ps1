# _record.ps1 - 延迟若干秒后连拍，拼宫格。挂在后台跑，不需要人和我配合。
param(
    [int]$DelaySec = 15,
    [int]$Count = 110,
    [int]$IntervalMs = 320,
    [double]$Scale = 0.45,
    [string]$Tag = 'rec'
)

$ErrorActionPreference = 'Continue'
. "C:\Users\26338\Fairy\packages\dsh-game-player\lib\helper.ps1"

Start-Sleep -Seconds $DelaySec

$game = @(Get-Windows '绝区零') | Where-Object { $_.title -eq '绝区零' } | Select-Object -First 1
if (-not $game) { "game window not found"; exit 1 }

$dsh = @(Get-Windows $null) | Where-Object { $_.title -like '*DeepSeek Harness*' } | Select-Object -First 1
if ($dsh) { [void][Gp]::ShowWindow([IntPtr][int64]$dsh.hwnd, 6); Start-Sleep -Milliseconds 400 }

$dir = Join-Path $env:TEMP ("rec-" + $Tag + "-" + (Get-Date -Format 'HHmmss'))
New-Item -ItemType Directory -Path $dir -Force | Out-Null
Write-Host "recording to $dir"

$t0 = [System.Diagnostics.Stopwatch]::StartNew()
for ($i = 0; $i -lt $Count; $i++) {
    try {
        $f = Capture-Frame $game.clientX $game.clientY $game.clientW $game.clientH $Scale
        Move-Item $f.path (Join-Path $dir ("frame{0:D3}.png" -f $i)) -Force
    } catch { }
    Start-Sleep -Milliseconds ([Math]::Max(0, $IntervalMs - 12))
}
Write-Host ("captured {0} frames in {1} ms" -f $Count, $t0.ElapsedMilliseconds)

$ff = "C:\Users\26338\.dsh\tools\ffmpeg\bin\ffmpeg.exe"
$outDir = "C:\Users\26338\Fairy\packages\dsh-game-player\tools"
$half = [int]($Count / 2)
foreach ($part in 0, 1) {
    $from = $part * $half
    $to = if ($part -eq 0) { $half - 1 } else { $Count - 1 }
    $sub = Join-Path $dir ("p{0}" -f $part)
    New-Item -ItemType Directory -Path $sub -Force | Out-Null
    for ($i = $from; $i -le $to; $i++) {
        Copy-Item (Join-Path $dir ("frame{0:D3}.png" -f $i)) (Join-Path $sub ("f{0:D3}.png" -f ($i - $from))) -Force
    }
    $out = Join-Path $outDir ("sheet-$Tag-$part.png")
    $cols = 10
    $rows = [Math]::Ceiling(($to - $from + 1) / $cols)
    & $ff -y -framerate 1 -i (Join-Path $sub 'f%03d.png') -vf "scale=256:144,tile=${cols}x${rows}:padding=3:color=black" -frames:v 1 $out 2> (Join-Path $env:TEMP "ff-$Tag-$part.log")
    Write-Host ("sheet {0}: {1}" -f $part, $out)
}
Write-Host "done"
