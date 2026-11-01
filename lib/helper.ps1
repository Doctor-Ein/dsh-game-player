<#
  helper.ps1 - 加载器（保持旧入口可用：tools/*.ps1 仍然 dot-source 这个文件）。

  真正的代码按职责拆在：
    win32.ps1   P/Invoke + 窗口查询
    eyes.ps1    截图 / 宫格 / 探针
    hands.ps1   键名 / 松手 / 急停
    run.ps1     steps 循环
    engine.ps1  JSON 分发

  顺序不能换：win32 先编译 [Gp]，后面都靠它。
#>

$here = $PSScriptRoot
foreach ($part in 'win32.ps1', 'eyes.ps1', 'positioning.ps1', 'hands.ps1', 'run.ps1', 'engine.ps1') {
    . (Join-Path $here $part)
}

# Hash the actual loaded engine manifest. The host uses the same byte hashes to
# reject a stale hand before arming, rather than guessing from the process name.
$engineFiles = 'lib/win32.ps1','lib/eyes.ps1','lib/positioning.ps1','lib/matcher.cs','lib/hands.ps1','lib/run.ps1','lib/engine.ps1','lib/helper.ps1','tools/game-hand.ps1'
$engineRoot = Split-Path $here -Parent
$sha = [System.Security.Cryptography.SHA256]::Create()
try {
    $hashes = @($engineFiles | ForEach-Object {
        ([BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes((Join-Path $engineRoot $_))))).Replace('-','').ToLowerInvariant()
    })
    $script:EngineRevision = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($hashes -join "`n"))))).Replace('-','').ToLowerInvariant()
}
finally { $sha.Dispose() }
