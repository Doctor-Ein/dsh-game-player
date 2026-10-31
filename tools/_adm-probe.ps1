# _adm-probe.ps1 - 提权后跑的三组对照实验：F1 / Esc / W。
# 结果写进同目录 probe-result.txt，截图也留在同目录，非提权的我读得到。

$ErrorActionPreference = 'Continue'
$outDir = $PSScriptRoot
$result = Join-Path $outDir 'probe-result.txt'
$lines = New-Object System.Collections.ArrayList
function Say([string]$m) { [void]$lines.Add($m); Write-Host $m }

. (Join-Path $PSScriptRoot '..\lib\helper.ps1')

$id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object System.Security.Principal.WindowsPrincipal($id)
Say ("=== probe start " + (Get-Date -Format 'HH:mm:ss') + " ===")
Say ("elevated: " + $pr.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator))

$all = @(Get-Windows $null)
$g = $all | Where-Object { $_.title -eq '绝区零' } | Select-Object -First 1
if (-not $g) {
    Say 'game window NOT FOUND'
    $lines | Set-Content -Path $result -Encoding UTF8
    exit 1
}
Say ("game: hwnd={0} pid={1} {2}x{3} at {4},{5}" -f $g.hwnd, $g.pid, $g.clientW, $g.clientH, $g.clientX, $g.clientY)

# 能不能读游戏进程（权限是否对等）
try { $gp = Get-Process -Id $g.pid -ErrorAction Stop; Say ("game process readable: " + $gp.ProcessName + "  path=" + $gp.Path) }
catch { Say ("game process NOT readable: " + $_.Exception.Message) }

$h = [IntPtr][int64]$g.hwnd
[void][Gp]::ShowWindow($h, 9)
Start-Sleep -Milliseconds 200
[void][Gp]::SetForegroundWindow($h)
Start-Sleep -Milliseconds 350
$info = Get-WindowInfo $h
Say ("foreground after focus: " + $info.foreground)

# 点一下窗口中心拿焦点
$cx = $info.clientX + [int]($info.clientW / 2)
$cy = $info.clientY + [int]($info.clientH / 2)
[Gp]::MouseMoveAbs($cx, $cy)
Start-Sleep -Milliseconds 60
[Gp]::MouseButton([Gp]::ME_LEFTDOWN)
Start-Sleep -Milliseconds 60
[Gp]::MouseButton([Gp]::ME_LEFTUP)
Start-Sleep -Milliseconds 400

function Shoot([string]$tag) {
    $s = Capture-Frame $info.clientX $info.clientY $info.clientW $info.clientH 0.4
    $dst = Join-Path $outDir ("probe-$tag.png")
    Copy-Item $s.path $dst -Force
    return $dst
}

function Compare([string]$a, [string]$b) {
    $b1 = [System.Drawing.Bitmap]::FromFile($a)
    $b2 = [System.Drawing.Bitmap]::FromFile($b)
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
    return "$diff / $n"
}

$base = Shoot 'base'

# 1) F1
$vk = Get-Vk 'f1'
[Gp]::KeySend([uint16]$vk, $false); Start-Sleep -Milliseconds 90; [Gp]::KeySend([uint16]$vk, $true)
Start-Sleep -Milliseconds 800
$f1 = Shoot 'f1'
Say ("F1  changed: " + (Compare $base $f1) + "  -> " + $f1)

# 关掉可能的菜单，回到大厅
$vk = Get-Vk 'esc'
[Gp]::KeySend([uint16]$vk, $false); Start-Sleep -Milliseconds 90; [Gp]::KeySend([uint16]$vk, $true)
Start-Sleep -Milliseconds 600
$esc = Shoot 'esc'
Say ("Esc changed: " + (Compare $f1 $esc) + "  -> " + $esc)

# 2) W 移动
$vk = Get-Vk 'w'
[Gp]::KeySend([uint16]$vk, $false)
Start-Sleep -Milliseconds 600
[Gp]::KeySend([uint16]$vk, $true)
Start-Sleep -Milliseconds 500
$w = Shoot 'w'
Say ("W   changed: " + (Compare $esc $w) + "  -> " + $w)

Say '=== probe end ==='
$lines | Set-Content -Path $result -Encoding UTF8
Write-Host ''
Write-Host ('result -> ' + $result) -ForegroundColor Green
