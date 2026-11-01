<#
  hands.ps1 - 手：键名映射、松手、急停检测。不截图、不做判断。

  依赖方向：只能往下用，不能往上调（eyes 永远不碰 run）。
  本文件由 lib/helper.ps1 按固定顺序 dot-source；单独执行没有意义。
#>

function Get-Vk([string]$name) {
    $k = "$name".Trim().ToLowerInvariant()
    $map = @{
        'esc' = 0x1B; 'escape' = 0x1B; 'tab' = 0x09; 'enter' = 0x0D; 'return' = 0x0D;
        'space' = 0x20; 'backspace' = 0x08; 'shift' = 0x10; 'ctrl' = 0x11; 'control' = 0x11;
        'alt' = 0x12; 'lshift' = 0xA0; 'rshift' = 0xA1; 'lctrl' = 0xA2; 'rctrl' = 0xA3;
        'win' = 0x5B;
        'up' = 0x26; 'down' = 0x28; 'left' = 0x25; 'right' = 0x27;
        'insert' = 0x2D; 'delete' = 0x2E; 'home' = 0x24; 'end' = 0x23;
        'pageup' = 0x21; 'pagedown' = 0x22;
        'f1' = 0x70; 'f2' = 0x71; 'f3' = 0x72; 'f4' = 0x73; 'f5' = 0x74; 'f6' = 0x75;
        'f7' = 0x76; 'f8' = 0x77; 'f9' = 0x78; 'f10' = 0x79; 'f11' = 0x7A; 'f12' = 0x7B;
        'mouseleft' = 0x01; 'mouseright' = 0x02; 'mousemiddle' = 0x04;
    }
    if ($map.ContainsKey($k)) { return [int]$map[$k] }
    if ($k -match '^[a-z]$') { return [int][char]$k.ToUpperInvariant() }
    if ($k -match '^[0-9]$') { return [int][char]$k }
    throw "unknown key: $name"
}

function Get-BtnFlag([string]$btn, [bool]$up) {
    switch ("$btn".ToLowerInvariant()) {
        'right' { if ($up) { return [Gp]::ME_RIGHTUP } else { return [Gp]::ME_RIGHTDOWN } }
        'middle' { if ($up) { return [Gp]::ME_MIDDLEUP } else { return [Gp]::ME_MIDDLEDOWN } }
        default { if ($up) { return [Gp]::ME_LEFTUP } else { return [Gp]::ME_LEFTDOWN } }
    }
}


# ---------------------------------------------------------------- 动作执行

$script:KnownVk = @()

function Test-Abort($key) {
    if (-not $key) { return $false }
    return [bool][Gp]::IsDown((Get-Vk $key))
}

function Release-All([switch]$Verify) {
    $failures = @()
    $vks = @()
    # 那个字符串里有个空格当分隔符，Get-Vk 不认空格 → 直接跳过，别让"松手"本身抛异常。
    foreach ($ch in 'wasdqe rfctvbnmhjkliopuxyzg1234'.ToCharArray()) {
        if ("$ch".Trim().Length -eq 0) { continue }
        try { $vks += (Get-Vk "$ch") } catch { }
    }
    $vks += 0x20, 0x10, 0x11, 0x12, 0x09, 0x1B
    foreach ($vk in ($vks | Select-Object -Unique)) {
        try { [Gp]::KeySend([uint16]$vk, $true) } catch { $failures += $_.Exception.Message }
    }
    foreach ($f in @([Gp]::ME_LEFTUP, [Gp]::ME_RIGHTUP, [Gp]::ME_MIDDLEUP)) {
        try { [Gp]::MouseButton($f) } catch { $failures += $_.Exception.Message }
    }
    $script:KnownVk = @()
    if ($Verify -and $failures.Count) { throw "input release failed: $($failures[0])" }
}


# Click coordinates, when supplied, are absolute physical screen pixels (including negatives).
function Move-ClickTarget($step) {
    if ($null -ne $step.x -or $null -ne $step.y) {
        if ($null -eq $step.x -or $null -eq $step.y) { throw 'click needs both x and y' }
        [Gp]::MouseMoveAbs([int]$step.x, [int]$step.y)
    }
}
