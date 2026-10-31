<#
  elevate.ps1 - 以管理员身份重新打开"手"。

  为什么不在 .cmd 里直接写 Start-Process -Verb RunAs：
    cmd 的引号转义很容易把路径弄坏，而且拉起的新窗口一出错就瞬间关闭（"黑框一闪"），
    什么信息都留不下。这里用 -NoExit，报错窗口会停住给人看。

  日志：<包目录>\elevate.log
#>

$ErrorActionPreference = 'Continue'
$pkgRoot = Split-Path $PSScriptRoot -Parent
$logFile = Join-Path $pkgRoot 'elevate.log'

function L([string]$m) {
    $line = '{0} {1}' -f (Get-Date -Format 'HH:mm:ss.fff'), $m
    try { Add-Content -Path $logFile -Value $line -Encoding UTF8 } catch { }
    Write-Host $line
}

$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path $ps)) { $ps = 'powershell.exe' }
$hand = Join-Path $PSScriptRoot 'game-hand.ps1'

L ('elevate requested; hand=' + $hand)

$idn = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = (New-Object System.Security.Principal.WindowsPrincipal($idn)).IsInRole(
    [System.Security.Principal.WindowsBuiltInRole]::Administrator)
L ('currently elevated=' + $isAdmin)

if ($isAdmin) {
    # 已经在提权环境里：直接跑手，出错也留着窗口
    L 'already elevated, launching hand in this window'
    & $ps -NoExit -NoProfile -ExecutionPolicy Bypass -File $hand
    exit 0
}

$argList = @('-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $hand + '"'))
L ('Start-Process -Verb RunAs ' + $ps + ' ' + ($argList -join ' '))
try {
    Start-Process -FilePath $ps -ArgumentList $argList -Verb RunAs -ErrorAction Stop
    L 'elevated process started (UAC accepted)'
    Write-Host ''
    Write-Host '  已请求管理员权限。如果弹了 UAC，请点"是"，会另开一个窗口。' -ForegroundColor Green
} catch {
    L ('elevate FAILED: ' + $_.Exception.Message)
    Write-Host ''
    Write-Host ('  提权失败：' + $_.Exception.Message) -ForegroundColor Red
    Write-Host '  （点了"否"也会是这个结果）' -ForegroundColor Yellow
}
