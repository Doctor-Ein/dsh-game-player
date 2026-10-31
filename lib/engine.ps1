<#
  engine.ps1 - 命令分发：一行 JSON 进来，一行 JSON 出去。

  依赖方向：只能往下用，不能往上调（eyes 永远不碰 run）。
  本文件由 lib/helper.ps1 按固定顺序 dot-source；单独执行没有意义。
#>

function Out-Json($obj) {
    $line = $obj | ConvertTo-Json -Compress -Depth 8
    $script:Out.WriteLine($line)
    $script:Out.Flush()
}


# ---------------------------------------------------------------- 命令分发
#
# 两种宿主共用这一层：
#   - tools/game-hand.ps1  命名管道客户端（小夏双击启动的"手"）
#   - 本文件的 stdio 模式  离线自测用
# 返回 hashtable 而不是字符串：由调用方决定往管道写还是往 stdout 写。

function Invoke-GpLine([string]$line) {
    if ($null -eq $line -or $line.Trim().Length -eq 0) { return $null }
    $id = 0
    try {
        $req = $line | ConvertFrom-Json
        $id = $req.id
        $cmd = "$($req.cmd)"
        $a = $req.args
        switch ($cmd) {
            'ping' { $res = @{ ok = $true; pid = $PID; tmp = $script:TmpDir } }
            'windows' {
                $ws = Get-Windows $a.filter
                $res = @{ windows = @($ws | Select-Object -First 40) }
            }
            'window' {
                $h = Resolve-Hwnd $a
                [void][Gp]::ShowWindow($h, 9)
                [void][Gp]::SetForegroundWindow($h)
                Start-Sleep -Milliseconds 120
                $res = Get-WindowInfo $h
            }
            'cap' {
                $res = Capture-Frame ([int]$a.x) ([int]$a.y) ([int]$a.w) ([int]$a.h) ([double]($a.scale))
            }
            'sheet' {
                $res = Build-Sheet @($a.paths) ([int]$a.cols) ([int]$a.cellW) @($a.labels)
            }
            'probe.flag' {
                # 离线回归：对一张整窗截图跑（主动 QTE 采样点）判据
                $res = Test-FlagImage ([string]$a.path)
            }
            'probe.counter' {
                # 离线回归：对一张整窗截图跑（反击采样点）判据
                $res = Test-CounterImage ([string]$a.path)
            }
            'probe.image' {
                # 离线回归：对一张 PNG 跑同一套 QTE 判据（C# 版 vs Python 版对账用）
                $res = Test-QteImage ([string]$a.path)
            }
            'run' { $res = Invoke-Run $a }
            'probe' {
                # 单次检查，用来标定颜色区域（返回命中像素数 + 包围盒）。
                $w0 = $null
                if ($a.hwnd) {
                    $wi = Get-WindowInfo ([IntPtr][int64]$a.hwnd)
                    $w0 = @{ x = $wi.clientX; y = $wi.clientY; w = $wi.clientW; h = $wi.clientH }
                }
                $pr = if ($a.probe) { $a.probe } else { 'qte' }
                $res = Test-Probe $pr $w0
            }
            'release' { Release-All; $res = @{ released = $true } }
            'cursor' {
                $p = New-Object Gp+POINT
                [void][Gp]::GetCursorPos([ref]$p)
                $res = @{ x = $p.X; y = $p.Y }
            }
            default { throw "unknown command: $cmd" }
        }
        return @{ id = $id; ok = $true; data = $res }
    } catch {
        return @{ id = $id; ok = $false; error = $_.Exception.Message }
    }
}

# ---------------------------------------------------------------- 入口点
#
# 本文件**只是引擎**：一堆函数 + 编译好的 Win32，不主动做任何事。
# 入口在 tools/ 下：
#   tools/game-hand.ps1    命名管道客户端（小夏双击的那只"手"）
#   tools/helper-stdio.ps1 stdio 模式，离线自测用
#
# 早先这里有个 `if (-not $env:GP_NO_STDIO_LOOP)` 守卫，实测在 -File 场景下读不到
# 调用方设的值（设完下一行就读出空），于是守卫失效、引擎被当成脚本入口跑起来。
# 结论：入口点别靠环境变量判断，直接拆文件。
