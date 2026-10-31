# _key-probe.ps1 - 对照实验：按 Esc 看有没有反应，判断"键到底有没有进游戏"。
param([string]$Key = 'esc', [string]$Tag = 'a')

. "C:\Users\26338\Fairy\packages\dsh-game-player\lib\helper.ps1"

$game = @(Get-Windows $null) | Where-Object { $_.title -eq '绝区零' } | Select-Object -First 1
if (-not $game) { "游戏窗口没找到"; exit 1 }
$h = [IntPtr][int64]$game.hwnd
[void][Gp]::ShowWindow($h, 9)
Start-Sleep -Milliseconds 150
[void][Gp]::SetForegroundWindow($h)
Start-Sleep -Milliseconds 400

$info = Get-WindowInfo $h
$vk = Get-Vk $Key
"key=$Key vk=$vk foreground=" + $info.foreground

$before = Capture-Frame $info.clientX $info.clientY $info.clientW $info.clientH 0.5
Start-Sleep -Milliseconds 200

[Gp]::KeySend([uint16]$vk, $false)
Start-Sleep -Milliseconds 90
[Gp]::KeySend([uint16]$vk, $true)

Start-Sleep -Milliseconds 900
$after = Capture-Frame $info.clientX $info.clientY $info.clientW $info.clientH 0.5

# 粗略比较两张图：抽样像素差
$b1 = [System.Drawing.Bitmap]::FromFile($before.path)
$b2 = [System.Drawing.Bitmap]::FromFile($after.path)
$diff = 0; $n = 0
for ($y = 20; $y -lt $b1.Height - 20; $y += 40) {
  for ($x = 20; $x -lt $b1.Width - 20; $x += 40) {
    $c1 = $b1.GetPixel($x, $y); $c2 = $b2.GetPixel($x, $y)
    $d = [Math]::Abs($c1.R - $c2.R) + [Math]::Abs($c1.G - $c2.G) + [Math]::Abs($c1.B - $c2.B)
    if ($d -gt 24) { $diff++ }
    $n++
  }
}
$b1.Dispose(); $b2.Dispose()
"changed samples: $diff / $n"
"before: " + $before.path
"after : " + $after.path
