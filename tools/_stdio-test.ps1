# _stdio-test.ps1 - 引擎（不经过管道）的端到端自测。
# 必须用 powershell -ExecutionPolicy Bypass -File 启动，否则 dot-source 会被策略拦住。

$ErrorActionPreference = 'Stop'
$dir = $PSScriptRoot
$stdio = Join-Path $dir 'helper-stdio.ps1'
$tmp = Join-Path $env:TEMP 'gp-io'
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$inF = Join-Path $tmp 'in.txt'
$outF = Join-Path $tmp 'out.txt'
$errF = Join-Path $tmp 'err.txt'

$lines = @(
  '{"id":1,"cmd":"ping"}'
  '{"id":2,"cmd":"windows","args":{}}'
  '{"id":3,"cmd":"run","args":{"actions":[{"t":"key","k":"f11","a":"tap","ms":40},{"t":"wait","ms":400}],"capture":{"x":0,"y":0,"w":640,"h":360,"every":300,"maxFrames":2,"scale":0.5}}}'
  '{"id":4,"cmd":"release"}'
)
[System.IO.File]::WriteAllLines($inF, $lines, (New-Object System.Text.UTF8Encoding($false)))

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = 'powershell.exe'
$psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $stdio + '"'
$psi.UseShellExecute = $false
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.CreateNoWindow = $true

$proc = [System.Diagnostics.Process]::Start($psi)
$proc.StandardInput.Write((Get-Content $inF -Raw))
$proc.StandardInput.Close()
$stdout = $proc.StandardOutput.ReadToEnd()
$stderr = $proc.StandardError.ReadToEnd()
$proc.WaitForExit(60000) | Out-Null
"exit=" + $proc.ExitCode
Write-Host '---- stdout ----'
$stdout -split "`r?`n" | Where-Object { $_.Trim() } | ForEach-Object {
  if ($_.Length -gt 300) { $_.Substring(0, 300) + '...' } else { $_ }
}
if ($stderr.Trim()) {
  Write-Host '---- stderr ----'
  $stderr -split "`r?`n" | Select-Object -First 8 | ForEach-Object { $_ }
}
