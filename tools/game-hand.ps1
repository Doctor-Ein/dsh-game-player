<#
  game-hand.ps1 - the HAND. Runs in 小夏's own PowerShell window, NOT inside DSH.

  It does two things:
    1. leaves a name card at %TEMP%\dsh-game-player\hand.json (pid + pipe name + startedAt)
    2. keeps trying to connect to \\.\pipe\dsh-game-player; once connected it is a
       remote-controlled keyboard and mouse (screen capture + SendInput).

  Why the hand connects to the plugin (and not the other way round):
    the plugin only listens on a pipe and never spawns a process. If the hand dies,
    DSH just shows "not connected" and normal chat is untouched.

  This file is saved as UTF-8 WITH BOM on purpose: Windows PowerShell 5.1 reads
  BOM-less .ps1 as ANSI (GBK here) and would mangle every Chinese string.

  Log: <package dir>\game-hand.log   (written BEFORE anything else, so a crash leaves evidence)
#>

param(
    [switch]$SelfTest,
    [string]$PipeName = 'dsh-game-player',
    [int]$RetryMs = 500
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# ------------------------------------------------------------------ 0. log first
$pkgRoot = Split-Path $PSScriptRoot -Parent
if (-not $pkgRoot) { $pkgRoot = $PSScriptRoot }
$logFile = Join-Path $pkgRoot 'game-hand.log'

function Write-Log([string]$msg) {
    $line = '{0} {1}' -f (Get-Date -Format 'HH:mm:ss.fff'), $msg
    try { Add-Content -Path $logFile -Value $line -Encoding UTF8 } catch { }
    try { Write-Host $line } catch { }
}

Write-Log ('===== start (pid={0}, selftest={1}, pipe={2}) =====' -f $PID, $SelfTest, $PipeName)
Write-Log ("ps={0} host={1} temp={2}" -f $PSVersionTable.PSVersion, $Host.Name, $env:TEMP)

$root = Join-Path $env:TEMP 'dsh-game-player'
$handFile = Join-Path $root 'hand.json'
$exitCode = 0

function Remove-OwnHandCard {
    try {
        $current = Get-Content -LiteralPath $handFile -Raw | ConvertFrom-Json
        if ([int]$current.pid -eq $PID) { Remove-Item -LiteralPath $handFile }
    } catch { }
}

try {
    if (-not (Test-Path $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }

    $helper = Join-Path $PSScriptRoot '..\lib\helper.ps1'
    Write-Log "loading engine: $helper"
    # helper.ps1 现在自带 UTF-8 BOM（Windows PowerShell 5.1 才会按 UTF-8 读中文注释），
    # 所以直接 dot-source 就行。曾经用 ReadAllText+scriptblock 绕过编码，结果函数和
    # 类型都没落进当前作用域（Get-Command Capture-Frame = False），反而更坑。
    . $helper
    # 引擎里必须有这两个东西，否则就是编码/解析出了问题 —— 报清楚，别静默继续。
    if (-not (Get-Command Capture-Frame -ErrorAction SilentlyContinue) -or -not ('Gp' -as [type])) {
        throw "engine failed to load from $helper (encoding or parse error)"
    }
    Write-Log 'engine loaded (Win32 compiled, DPI aware)'

    $card = [ordered]@{
        engineVersion = $script:EngineVersion
        engineRevision = $script:EngineRevision
        coordinateSystem = $script:CoordinateSystem
        pid       = $PID
        pipe      = $PipeName
        startedAt = (Get-Date).ToString('o')
        psVersion = $PSVersionTable.PSVersion.ToString()
        mode      = $(if ($SelfTest) { 'selftest' } else { 'play' })
    }
    if (-not $SelfTest) {
        $card | ConvertTo-Json -Compress | Set-Content -Path $handFile -Encoding UTF8
        Write-Log "name card: $handFile"
    }

    # -------------------------------------------------------------- selftest
    if ($SelfTest) {
        $w = [Gp]::GetSystemMetrics(0)
        $h = [Gp]::GetSystemMetrics(1)
        Write-Log "primary screen ${w}x${h}, capturing..."
        $shot = Capture-Frame 0 0 $w $h 0.5
        Write-Log "shot: $($shot.path) ($($shot.w)x$($shot.h))"
        Write-Log 'SELFTEST PASSED'
        Write-Host ''
        Write-Host ('  SELFTEST PASSED  ->  ' + $shot.path) -ForegroundColor Green
        if (-not $env:GP_NO_PAUSE) { Read-Host 'press Enter to close' }
        return
    }

    # -------------------------------------------------------------- connect loop
    # 提权状态必须在 hello 里告诉插件：不提权的话 SendInput 会被 UIPI 静默丢掉，
    # 游戏里"发出去了但没反应"，排查起来极其费时（我们在这儿卡了很久）。
    $isAdmin = $false
    try {
        $idn = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $isAdmin = (New-Object System.Security.Principal.WindowsPrincipal($idn)).IsInRole(
            [System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { }
    Write-Host ''
    if ($isAdmin) {
        Write-Host '  running as ADMINISTRATOR - input injection will reach the game' -ForegroundColor Green
    } else {
        Write-Host '  NOT elevated - keystrokes will be silently dropped by Windows (UIPI).' -ForegroundColor Yellow
        Write-Host '  close this window and use the launcher that asks for admin rights.' -ForegroundColor Yellow
    }
    Write-Host '  hand is ready, waiting for /game in DSH ... (keep this window open)' -ForegroundColor Cyan

    while ($true) {
        $writer = $null; $reader = $null; $pipe = $null; $hadConnection = $false
        try {
            $pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', $PipeName, [System.IO.Pipes.PipeDirection]::InOut)
            $pipe.Connect(1500)
            $hadConnection = $true
            $reader = New-Object System.IO.StreamReader($pipe, [System.Text.Encoding]::UTF8)
            $writer = New-Object System.IO.StreamWriter($pipe, (New-Object System.Text.UTF8Encoding($false)))
            $writer.AutoFlush = $true
            $writer.WriteLine((@{ hello = $true; pid = $PID; mode = 'pipe'; elevated = $isAdmin; engineVersion = $script:EngineVersion; engineRevision = $script:EngineRevision; coordinateSystem = $script:CoordinateSystem } | ConvertTo-Json -Compress))
            Write-Log ('CONNECTED - hand attached (elevated={0}), listening to DSH' -f $isAdmin)

            while ($true) {
                $line = $reader.ReadLine()
                if ($null -eq $line) { break }
                if ($line.Trim().Length -eq 0) { continue }
                $resp = Invoke-GpLine $line
                if ($null -ne $resp) {
                    $writer.WriteLine(($resp | ConvertTo-Json -Compress -Depth 8))
                }
            }
            Write-Log 'DISCONNECTED - back to waiting'
        } catch {
            # 每隔 500ms 重试一次，失败是常态（插件还没开会话）。只记"变化"，
            # 否则日志会被同一条错误刷成几 MB。
            $msg = $_.Exception.Message
            if ($msg -ne $script:lastConnMsg) {
                $script:lastConnMsg = $msg
                Write-Log "connect wait: $msg"
            }
        } finally {
            try { if ($hadConnection) { Release-All } } catch { }
            try { if ($writer) { $writer.Dispose() } } catch { }
            try { if ($reader) { $reader.Dispose() } } catch { }
            try { if ($pipe) { $pipe.Dispose() } } catch { }
        }
        Start-Sleep -Milliseconds $RetryMs
    }
} catch {
    $exitCode = 1
    Write-Log "FATAL: $($_.Exception.Message)"
    if ($_.ScriptStackTrace) { Write-Log ('  at ' + ($_.ScriptStackTrace -replace "`r?`n", ' | ')) }
    Write-Host ''
    Write-Host ('  FAILED: ' + $_.Exception.Message) -ForegroundColor Red
    if (-not $env:GP_NO_PAUSE) { Read-Host 'press Enter to close' }
} finally {
    try { Release-All } catch { }
    Remove-OwnHandCard
    Write-Log 'game-hand stopped, all keys released'
}

exit $exitCode
