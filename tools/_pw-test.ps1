# _pw-test.ps1 - 验证 PrintWindow(PW_RENDERFULLCONTENT) 能不能抓到被遮挡的游戏窗口。
# 成功的话，capture 就不再依赖"游戏必须在最前"。

Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PW {
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hwnd, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT r);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
'@

$hwnd = [IntPtr]1574288
$r = New-Object PW+RECT
[void][PW]::GetClientRect($hwnd, [ref]$r)
$w = $r.Right - $r.Left
$h = $r.Bottom - $r.Top
"client ${w}x${h}"

$bmp = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$hdc = $g.GetHdc()
# 2 = PW_RENDERFULLCONTENT (Win 8.1+)，DX 游戏才可能给内容
$ok = [PW]::PrintWindow($hwnd, $hdc, 2)
$g.ReleaseHdc($hdc)
$g.Dispose()
"PrintWindow returned=" + $ok

# 判断是不是全黑
$samples = @()
for ($y = 100; $y -lt $h; $y += 200) {
  for ($x = 100; $x -lt $w; $x += 200) {
    $c = $bmp.GetPixel($x, $y)
    $samples += ($c.R + $c.G + $c.B)
  }
}
$nonBlack = @($samples | Where-Object { $_ -gt 30 }).Count
"sampled=" + $samples.Count + " nonBlack=" + $nonBlack

$out = Join-Path $env:TEMP ("pw-" + [guid]::NewGuid().ToString('N').Substring(0,6) + ".png")
$bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
"saved: $out"
