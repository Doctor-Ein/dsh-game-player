<#
  run.ps1 - 调度：按顺序走 steps，到时取帧，记 trace。唯一知道"顺序"的地方。

  依赖方向：只能往下用，不能往上调（eyes 永远不碰 run）。
  本文件由 lib/helper.ps1 按固定顺序 dot-source；单独执行没有意义。
#>

# 执行 waitfor 的 then。守卫模式会被重复调用，所以抽成函数。
# 用 hashtable 传状态：函数内改 $state.aborted 能传回调用方（引用类型）。
function Invoke-ThenSteps($thens, [hashtable]$state) {
    foreach ($th in @($thens)) {
        if (-not $th) { continue }
        if (Test-Abort $state.abortKey) { $state.aborted = $true; return }
        $tt = "$($th.t)".ToLowerInvariant()
        switch ($tt) {
            'key' {
                $vk = Get-Vk $th.k
                $rep = if ($th.repeat) { [int][Math]::Max(1, [Math]::Min(20, $th.repeat)) } else { 1 }
                $holdMs = if ($th.ms) { [int]$th.ms } else { 60 }
                $gapMs = if ($th.gap) { [int]$th.gap } else { 60 }
                for ($i = 0; $i -lt $rep; $i++) {
                    [Gp]::KeySend([uint16]$vk, $false)
                    Start-Sleep -Milliseconds $holdMs
                    [Gp]::KeySend([uint16]$vk, $true)
                    if ($i -lt ($rep - 1)) { Start-Sleep -Milliseconds $gapMs }
                }
                [void]$state.trace.Add(@{ t = 'then:key'; k = "$($th.k)"; repeat = $rep })
            }
            'mouse' {
                $btn = if ($th.btn) { "$($th.btn)" } else { 'left' }
                $rep = if ($th.repeat) { [int][Math]::Max(1, [Math]::Min(20, $th.repeat)) } else { 1 }
                $holdMs = if ($th.ms) { [int]$th.ms } else { 45 }
                $gapMs = if ($th.gap) { [int]$th.gap } else { 60 }
                for ($i = 0; $i -lt $rep; $i++) {
                    [Gp]::MouseButton((Get-BtnFlag $btn $false))
                    Start-Sleep -Milliseconds $holdMs
                    [Gp]::MouseButton((Get-BtnFlag $btn $true))
                    if ($i -lt ($rep - 1)) { Start-Sleep -Milliseconds $gapMs }
                }
                [void]$state.trace.Add(@{ t = 'then:mouse'; btn = $btn; repeat = $rep })
            }
            'wait' { Start-Sleep -Milliseconds ([int]$th.ms) }
            'look' { if ($state.snap) { & $state.snap } }
            default { }
        }
    }
}

function Invoke-Run($opt) {
    $actions = @($opt.actions)
    $cap = $opt.capture
    $abortKey = if ($opt.abortKey) { "$($opt.abortKey)" } else { 'F12' }
    if ($actions.Count -gt 60) { throw "too many actions in one block ($($actions.Count) > 60)" }


    # 窗口锁：绑定的窗口不在前台就一个键都不发（除非上层显式允许后台输入）。
    if ($opt.requireForeground -and $opt.hwnd) {
        $want = [IntPtr][int64]$opt.hwnd
        if ([Gp]::GetForegroundWindow() -ne $want) {
            throw 'bound window is not foreground: input refused (bring it forward, or arm with allowBackground)'
        }
    }

    # 探针要按窗口客户区算比例坐标，所以这里先把窗口矩形拿好（跟截图无关）。
    $win = $null
    if ($opt.hwnd) {
        try {
            $wi = Get-WindowInfo ([IntPtr][int64]$opt.hwnd)
            $win = @{ x = $wi.clientX; y = $wi.clientY; w = $wi.clientW; h = $wi.clientH }
        } catch { }
    }

    $rect = $null
    if ($cap -and $cap.enabled -ne $false) {
        if ($cap.hwnd -or $cap.window) {
            $h = Resolve-Hwnd @{ hwnd = $cap.hwnd; window = $cap.window }
            $info = Get-WindowInfo $h
            $rect = @{ x = $info.clientX; y = $info.clientY; w = $info.clientW; h = $info.clientH }
        } elseif ($cap.w) {
            $rect = @{ x = [int]$cap.x; y = [int]$cap.y; w = [int]$cap.w; h = [int]$cap.h }
        }
    }

    $every = if ($cap -and $cap.every) { [int]$cap.every } else { 1000 }
    $maxFrames = if ($cap -and $cap.maxFrames) { [int]$cap.maxFrames } else { 6 }
    $scale = if ($cap -and $cap.scale) { [double]$cap.scale } else { 1.0 }

    $frames = New-Object System.Collections.ArrayList
    $labels = New-Object System.Collections.ArrayList
    $trace = New-Object System.Collections.ArrayList
    $aborted = $false
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $nextCap = 0

    $snap = {
        if (-not $rect) { return }
        if ($frames.Count -ge $maxFrames) { return }
        try {
            $f = Capture-Frame $rect.x $rect.y $rect.w $rect.h $scale
            [void]$frames.Add($f.path)
            [void]$labels.Add(("{0}  {1:N1}s" -f ($frames.Count), ($sw.Elapsed.TotalSeconds)))
        } catch { }
    }

    foreach ($a in $actions) {
        if ($sw.Elapsed.TotalMilliseconds -ge $nextCap) {
            & $snap
            $nextCap = $sw.Elapsed.TotalMilliseconds + $every
        }
        if (Test-Abort $abortKey) { $aborted = $true; break }

        $t = "$($a.t)".ToLowerInvariant()
        try {
            switch ($t) {
                'key' {
                    $vk = Get-Vk $a.k
                    $mode = if ($a.a) { "$($a.a)" } else { 'tap' }
                    $hold = if ($a.ms) { [int]$a.ms } else { 60 }
                    $rep = if ($a.repeat) { [int][Math]::Max(1, [Math]::Min(30, $a.repeat)) } else { 1 }
                    $gap = if ($a.gap) { [int]$a.gap } else { 40 }
                    for ($i = 0; $i -lt $rep; $i++) {
                        if ($mode -eq 'down') { [Gp]::KeySend([uint16]$vk, $false); break }
                        if ($mode -eq 'up') { [Gp]::KeySend([uint16]$vk, $true); break }
                        [Gp]::KeySend([uint16]$vk, $false)
                        $s = [System.Diagnostics.Stopwatch]::StartNew()
                        while ($s.ElapsedMilliseconds -lt $hold) {
                            if (Test-Abort $abortKey) { $aborted = $true; break }
                            Start-Sleep -Milliseconds 10
                        }
                        [Gp]::KeySend([uint16]$vk, $true)
                        if ($aborted) { break }
                        if ($i -lt ($rep - 1)) { Start-Sleep -Milliseconds $gap }
                    }
                }
                'mouse' {
                    $m = if ($a.a) { "$($a.a)" } else { 'click' }
                    switch ($m) {
                        'rel' { [Gp]::MouseMoveRel([int]$a.dx, [int]$a.dy) }
                        'abs' { [Gp]::MouseMoveAbs([int]$a.x, [int]$a.y) }
                        'down' { [Gp]::MouseButton((Get-BtnFlag $a.btn $false)) }
                        'up' { [Gp]::MouseButton((Get-BtnFlag $a.btn $true)) }
                        'wheel' { [Gp]::Wheel([int]$a.dy) }
                        default {
                            $hold = if ($a.ms) { [int]$a.ms } else { 50 }
                            [Gp]::MouseButton((Get-BtnFlag $a.btn $false))
                            Start-Sleep -Milliseconds $hold
                            [Gp]::MouseButton((Get-BtnFlag $a.btn $true))
                        }
                    }
                }
                'wait' {
                    $ms = [int]$a.ms
                    $s = [System.Diagnostics.Stopwatch]::StartNew()
                    while ($s.ElapsedMilliseconds -lt $ms) {
                        if ($sw.Elapsed.TotalMilliseconds -ge $nextCap) {
                            & $snap
                            $nextCap = $sw.Elapsed.TotalMilliseconds + $every
                        }
                        if (Test-Abort $abortKey) { $aborted = $true; break }
                        $left = $ms - $s.ElapsedMilliseconds
                        Start-Sleep -Milliseconds ([int][Math]::Min(30, [Math]::Max(5, $left)))
                    }
                }
                'look' { & $snap; $nextCap = $sw.Elapsed.TotalMilliseconds + $every }
                'waitfor' {
                    # 两种用法：
                    #   单探针  {"probe":"qte","holdMs":..,"gapMs":..,"then":{...}}
                    #   多探针  {"probes":[{"probe":"a","gapMs":..,"then":{...}}, {"probe":"b",...}]}
                    # 多探针是"真并行"：每一轮循环把每个探针都判一次，各发各的键，
                    # 互不阻塞。为什么需要：反击会连着出两个，顺序等待中间那段时间就是盲区。
                    #
                    # holdMs=0 是旧行为（看见一次就结束）；holdMs>0 是守卫，守满才停。
                    $timeout = if ($a.timeoutMs) { [int]$a.timeoutMs } else { 1200 }
                    $hold = if ($a.holdMs) { [int]$a.holdMs } else { 0 }
                    $gap = if ($a.gapMs) { [int]$a.gapMs } else { 200 }
                    $interval = if ($a.intervalMs) { [int]$a.intervalMs } else { 40 }
                    $timeout = [Math]::Min(15000, [Math]::Max(100, $timeout))
                    $hold = [Math]::Min(120000, [Math]::Max(0, $hold))
                    $gap = [Math]::Min(2000, [Math]::Max(0, $gap))
                    $interval = [Math]::Min(500, [Math]::Max(5, $interval))
                    $deadline = if ($hold -gt 0) { $hold } else { $timeout }

                    $state = @{ abortKey = $abortKey; aborted = $aborted; trace = $trace; snap = $snap }
                    $targets = New-Object System.Collections.ArrayList
                    if ($a.probes) {
                        foreach ($p in @($a.probes)) {
                            [void]$targets.Add(@{
                                probe = $(if ($p.probe) { $p.probe } else { 'qte' })
                                then  = $p.then
                                gap   = $(if ($p.gapMs) { [int]$p.gapMs } else { $gap })
                                last  = -100000
                                fires = (New-Object System.Collections.ArrayList)
                                count = 0
                            })
                        }
                    } else {
                        [void]$targets.Add(@{
                            probe = $(if ($a.probe) { $a.probe } else { 'qte' })
                            then  = $a.then
                            gap   = $gap
                            last  = -100000
                            fires = (New-Object System.Collections.ArrayList)
                            count = 0
                        })
                    }

                    $s = [System.Diagnostics.Stopwatch]::StartNew()
                    while ($s.ElapsedMilliseconds -lt $deadline) {
                        if (Test-Abort $abortKey) { $aborted = $true; break }
                        foreach ($tg in $targets) {
                            $r = $null
                            try { $r = Test-Probe $tg.probe $win }
                            catch {
                                [Console]::Error.WriteLine("probe failed: $(if ($tg.probe -is [string]) { $tg.probe } else { 'inline' }) $($_.Exception.Message)")
                                continue
                            }
                            if ($r -and $r.hit -and (($s.ElapsedMilliseconds - $tg.last) -ge $tg.gap)) {
                                $tg.last = [int]$s.ElapsedMilliseconds
                                $tg.count = $r.count
                                [void]$tg.fires.Add($tg.last)
                                [void]$trace.Add(@{ t = 'fire'; probe = $(if ($tg.probe -is [string]) { $tg.probe } else { 'inline' }); at = $tg.last; count = $r.count })
                                Invoke-ThenSteps $tg.then $state
                                $aborted = $state.aborted
                                if ($aborted) { break }
                            }
                        }
                        if ($aborted) { break }
                        if ($hold -le 0) {
                            $any = $false
                            foreach ($tg in $targets) { if ($tg.fires.Count -gt 0) { $any = $true } }
                            if ($any) { break }
                        }
                        Start-Sleep -Milliseconds $interval
                    }
                    foreach ($tg in $targets) {
                        [void]$trace.Add(@{
                            t      = 'waitfor'
                            probe  = $(if ($tg.probe -is [string]) { $tg.probe } else { "inline" })
                            hit    = ($tg.fires.Count -gt 0)
                            waited = [int]$s.ElapsedMilliseconds
                            count  = $tg.count
                            mode   = $(if ($hold -gt 0) { 'guard' } else { 'once' })
                            fires  = @($tg.fires)
                        })
                    }
                }
                default { throw "unknown step type: $t" }
            }
        } catch {
            [Console]::Error.WriteLine("action failed: $t $($_.Exception.Message)")
            [void]$trace.Add(@{ t = $t; err = $_.Exception.Message })
        }
        [void]$trace.Add(@{ t = $t; at = [int]$sw.Elapsed.TotalMilliseconds })
        if ($aborted) { break }
    }

    if ($rect -and $frames.Count -lt $maxFrames) { & $snap }

    if ($aborted) { Release-All }

    return @{
        frames   = @($frames)
        labels   = @($labels)
        aborted  = $aborted
        ms       = [int]$sw.Elapsed.TotalMilliseconds
        trace    = @($trace)
    }
}

