# _win-test.ps1 - 单独验证窗口枚举（EnumWindows 的委托回调最容易静默失败）
. "C:\Users\26338\Fairy\packages\dsh-game-player\lib\helper.ps1"

"Gp=" + [bool]('Gp' -as [type])
$all = @(Get-Windows $null)
"Get-Windows null count=" + $all.Count
$all | Select-Object -First 8 | ForEach-Object { "  [{0}] {1}" -f $_.pid, $_.title }

"--- direct EnumWindows probe ---"
$found = New-Object System.Collections.ArrayList
$cb = [Gp+EnumWindowsProc] {
    param($h, $l)
    try {
        $sb = New-Object System.Text.StringBuilder 256
        [void][Gp]::GetWindowTextW($h, $sb, 256)
        $t = $sb.ToString()
        if ($t.Trim().Length -gt 0) { [void]$found.Add($t) }
    } catch { }
    return $true
}
$ok = [Gp]::EnumWindows($cb, [IntPtr]::Zero)
"EnumWindows returned=" + $ok + " titles=" + $found.Count
$found | Select-Object -First 5 | ForEach-Object { "  " + $_ }
