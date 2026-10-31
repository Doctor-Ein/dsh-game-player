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
foreach ($part in 'win32.ps1', 'eyes.ps1', 'hands.ps1', 'run.ps1', 'engine.ps1') {
    . (Join-Path $here $part)
}
