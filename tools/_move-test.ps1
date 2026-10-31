# _move-test.ps1 - 点一下窗口中心拿到焦点，再按住 W 600ms，看角色会不会动。
. "C:\Users\26338\Fairy\packages\dsh-game-player\lib\helper.ps1"

$game = @(Get-Windows $null) | Where-Object { $_.title -eq '绝区零' } | Select-Object -First 1
if (-not $game) { "游戏窗口没找到"; exit 1 }
$h = [IntPtr][int64]$game.hwnd
[void][Gp]::ShowWindow($h, 9)
Start-Sleep -Milliseconds 150
[void][Gp]::SetForegroundWindow($h)
Start-Sleep -Milliseconds 300
$info = Get-WindowInfo $h
"game {0}x{1} at {2},{3} foreground={4}" -f $info.clientW, $info.clientH, $info.clientX, $info.clientY, $info.foreground

# 1) 先点一下窗口中心，确保它拿到键盘焦点
$cx = $info.clientX + [int]($info.clientW / 2)
$cy = $info.clientY + [int]($info.clientH / 2)
"click at $cx,$cy"
[Gp]::MouseMoveAbs($cx, $cy)
Start-Sleep -Milliseconds 60
[Gp]::MouseButton([Gp]::ME_LEFTDOWN)
Start-Sleep -Milliseconds 60
[Gp]::MouseButton([Gp]::ME_LEFTUP)
Start-Sleep -Milliseconds 500

$before = Capture-Frame $info.clientX $info.clientY $info.clientW $info.clientH 0.4

# 2) 按住 W 600ms
$vk = Get-Vk 'w'
"holding W (vk=$vk) for 600ms"
[Gp]::KeySend([uint16]$vk, $false)
Start-Sleep -Milliseconds 600
[Gp]::KeySend([uint16]$vk, $true)
Start-Sleep -Milliseconds 400

$after = Capture-Frame $info.clientX $info.clientY $info.clientW $info.clientH 0.4

$b1 = [System.Drawing.Bitmap]::FromFile($before.path)
$b2 = [System.Drawing.Bitmap]::FromFile($after.path)
$diff = 0; $n = 0
for ($y = 20; $y -lt $b1.Height - 20; $y += 30) {
  for ($x = 20; $x -lt $b1.Width - 20; $x += 30) {
    $c1 = $b1.GetPixel($x, $y); $c2 = $b2.GetPixel($x, $y)
    $d = [Math]::Abs($c1.R - $c2.R) + [Math]::Abs($c1.G - $c2.G) + [Math]::Abs($c1.B - $c2.B)
    if ($d -gt 30) { $diff++ }
    $n++
  }
}
$b1.Dispose(); $b2.Dispose()
"changed: $diff / $n"
"before: " + $before.path
"after : " + $after.path
