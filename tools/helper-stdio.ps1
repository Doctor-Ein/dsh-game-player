<#
  helper-stdio.ps1 - stdio 入口，纯离线自测用（不出图，不需要 DSH）。

  一行一个 JSON 进来，一行一个 JSON 出去：
    {"id":1,"cmd":"ping"}
    {"id":2,"cmd":"cap","args":{"x":0,"y":0,"w":800,"h":450,"scale":0.5}}

  引擎在 lib/helper.ps1。这里显式按 UTF-8 读它，绕开 Windows PowerShell 5.1
  对"无 BOM 的 .ps1 按 ANSI 读"的默认行为（中文注释会把后面的 ASCII 标点吞掉）。
#>

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$engine = Join-Path $PSScriptRoot '..\lib\helper.ps1'
# helper.ps1 带 UTF-8 BOM，直接 dot-source（scriptblock 那条路会把函数丢在临时作用域里）。
. $engine

Out-Json @{ hello = $true; pid = $PID; mode = 'stdio' }

while ($true) {
    $line = [Console]::In.ReadLine()
    if ($null -eq $line) { break }
    $resp = Invoke-GpLine $line
    if ($null -ne $resp) { Out-Json $resp }
}

Release-All
