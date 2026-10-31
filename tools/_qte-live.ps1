# _qte-live.ps1 - 在真实窗口上跑一次 waitfor + qte 探针（期望：没 QTE → 超时跳过）
. "C:\Users\26338\Fairy\packages\dsh-game-player\lib\helper.ps1"

$target = @(Get-Windows '绝区零') | Select-Object -First 1
if (-not $target) { $target = @(Get-Windows $null) | Select-Object -First 1 }
"window: {0} {1}x{2}" -f $target.title, $target.clientW, $target.clientH

$r = Invoke-Run @{
    actions = @(
        @{ t = 'waitfor'; probe = 'qte'; timeoutMs = 600
           then = @{ t = 'mouse'; a = 'click'; btn = 'left'; repeat = 1 } }
    )
    capture = @{ enabled = $false }
    abortKey = 'F12'
    hwnd = $target.hwnd
}
"aborted={0} ms={1}" -f $r.aborted, $r.ms
$r.trace | ForEach-Object { "  " + ($_ | ConvertTo-Json -Compress) }
