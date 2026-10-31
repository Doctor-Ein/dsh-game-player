# _pipe-test.ps1 - 自己当 10 秒钟的插件：建管道、等手上门、发几条命令、看回包。
# 不碰 DSH，只在本地验证「手 <-> 管道」这条链路。

$ErrorActionPreference = 'Stop'
$hand = "C:\Users\26338\Fairy\packages\dsh-game-player\tools\game-hand.ps1"
$env:GP_NO_PAUSE = '1'

$pipe = New-Object System.IO.Pipes.NamedPipeServerStream(
    'dsh-game-player',
    [System.IO.Pipes.PipeDirection]::InOut,
    1,
    [System.IO.Pipes.PipeTransmissionMode]::Byte,
    [System.IO.Pipes.PipeOptions]::Asynchronous)

Write-Host 'server: waiting for the hand...'
$wait = $pipe.WaitForConnectionAsync()
$proc = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $hand) -PassThru -WindowStyle Minimized

if (-not $wait.Wait(20000)) { throw 'hand did not connect within 20s' }
Write-Host ('server: connected; hand pid=' + $proc.Id)

$reader = New-Object System.IO.StreamReader($pipe, [System.Text.Encoding]::UTF8)
$writer = New-Object System.IO.StreamWriter($pipe, (New-Object System.Text.UTF8Encoding($false)))
$writer.AutoFlush = $true

function Send-Cmd([string]$json) {
    $writer.WriteLine($json)
    return $reader.ReadLine()
}

Write-Host ('hello  <- ' + $reader.ReadLine())
Write-Host ('ping   <- ' + (Send-Cmd '{"id":1,"cmd":"ping"}'))
Write-Host ('cursor <- ' + (Send-Cmd '{"id":2,"cmd":"cursor"}'))
Write-Host ('windows<- ' + (Send-Cmd '{"id":3,"cmd":"windows","args":{"filter":"绝区零"}}'))
Write-Host 'run: one harmless key + wait, sampling 2 frames...'
$run = Send-Cmd '{"id":4,"cmd":"run","args":{"actions":[{"t":"key","k":"f24","a":"tap","ms":50},{"t":"wait","ms":600}],"capture":{"x":0,"y":0,"w":800,"h":450,"every":400,"maxFrames":2,"scale":0.5}}}'
Write-Host ('run    <- ' + $run)
Write-Host 'release...'
Write-Host ('release<- ' + (Send-Cmd '{"id":5,"cmd":"release"}'))

$writer.Dispose(); $reader.Dispose(); $pipe.Dispose()
Start-Sleep -Milliseconds 500
if (-not $proc.HasExited) { $proc.Kill() }
Write-Host 'PIPE-TEST OK'
