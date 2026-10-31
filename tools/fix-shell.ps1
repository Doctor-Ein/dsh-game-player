<#
  fix-shell.ps1 - 一次把三件事做完，全程写日志，供后续排查：
    1. 报告各作用域的 ExecutionPolicy
    2. Unblock-File 掉 node_modules 下所有 .ps1（含 .pnpm 里的真身）
    3. 把 CurrentUser 设成 RemoteSigned
    4. 用一份临时未签名脚本验证"现在能不能跑本地脚本了"
    5. 顺手跑一遍 game-hand 的 selftest，把结果也记进来

  由 fix-shell.cmd 以 -ExecutionPolicy Bypass 启动，所以它自己不会被策略拦住。
  日志：<包目录>\fix-shell.log
#>

$ErrorActionPreference = 'Continue'
$pkgRoot = Split-Path $PSScriptRoot -Parent
$logFile = Join-Path $pkgRoot 'fix-shell.log'
if (Test-Path $logFile) { Remove-Item $logFile -Force -ErrorAction SilentlyContinue }

function L([string]$m) {
    $line = '{0} {1}' -f (Get-Date -Format 'HH:mm:ss.fff'), $m
    try { Add-Content -Path $logFile -Value $line -Encoding UTF8 } catch { }
    try { Write-Host $line } catch { }
}

L '===== fix-shell start ====='
L ("user={0} ps={1}" -f $env:USERNAME, $PSVersionTable.PSVersion)

L '--- execution policy by scope ---'
foreach ($scope in 'MachinePolicy', 'UserPolicy', 'Process', 'CurrentUser', 'LocalMachine') {
    try { L ("  {0,-14} {1}" -f $scope, (Get-ExecutionPolicy -Scope $scope)) }
    catch { L ("  {0,-14} <error> {1}" -f $scope, $_.Exception.Message) }
}

L '--- unblock .ps1 under profile node_modules ---'
$nm = Join-Path $env:USERPROFILE '.dsh\profiles\desktop\node_modules'
$count = 0
try {
    $files = Get-ChildItem -Path $nm -Recurse -Filter '*.ps1' -File -ErrorAction SilentlyContinue
    foreach ($f in $files) {
        try { Unblock-File -Path $f.FullName -ErrorAction Stop; $count++ }
        catch { L ("  unblock FAILED: {0} :: {1}" -f $f.FullName, $_.Exception.Message) }
    }
    L ("  scanned {0} .ps1, unblocked {1}" -f @($files).Count, $count)
} catch {
    L ("  walk failed: " + $_.Exception.Message)
}

L '--- set CurrentUser policy ---'
try {
    Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force -ErrorAction Stop
    L '  Set-ExecutionPolicy OK'
} catch {
    L ('  Set-ExecutionPolicy FAILED: ' + $_.Exception.Message)
}
try { L ('  CurrentUser now: ' + (Get-ExecutionPolicy -Scope CurrentUser)) } catch { }
try { L ('  effective now: ' + (Get-ExecutionPolicy)) } catch { }

L '--- can a plain unsigned local script run now? ---'
$probe = Join-Path $env:TEMP 'dsh-policy-probe.ps1'
try {
    Set-Content -Path $probe -Value 'Write-Output "PROBE OK"' -Encoding ASCII
    $probeOut = & powershell -NoProfile -File $probe 2>&1 | Out-String
    L ("  exit={0} out={1}" -f $LASTEXITCODE, ($probeOut.Trim() -replace "`r?`n", ' '))
} catch {
    L ('  probe threw: ' + $_.Exception.Message)
} finally {
    Remove-Item $probe -Force -ErrorAction SilentlyContinue
}

L '--- run game-hand selftest ---'
$env:GP_NO_PAUSE = '1'
$hand = Join-Path $pkgRoot 'tools\game-hand.ps1'
$handOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $hand -SelfTest 2>&1 | Out-String
L ("  exit={0}" -f $LASTEXITCODE)
foreach ($ln in ($handOut -split "`r?`n")) { if ($ln.Trim()) { L ('  | ' + $ln.Trim()) } }

L '===== fix-shell done ====='
Write-Host ''
Write-Host ('Done. Log: ' + $logFile) -ForegroundColor Green
Write-Host ('Selftest screenshot should be in ' + (Join-Path $env:TEMP 'dsh-game-player')) -ForegroundColor Green
