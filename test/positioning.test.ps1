param([switch]$CursorCheck)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'lib/helper.ps1')
$testDir = Join-Path $env:TEMP ('dsh-position-test-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $testDir)
$script:TmpDir = $testDir
$script:TemplateDir = Join-Path $testDir 'templates'
$checks = 0
function Assert($condition, $message) {
    if (-not $condition) { throw "FAIL: $message" }
    $script:checks++
}
function Throws($action, $message) {
    $threw = $false
    try { & $action } catch { $threw = $true }
    Assert $threw $message
}

Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class PositionTestWindow {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int l,t,r,b; }
    public delegate bool MonitorProc(IntPtr monitor, IntPtr dc, ref Rect rect, IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr dc, IntPtr clip, MonitorProc callback, IntPtr data);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr CreateWindowEx(int ex, string cls, string title, uint style, int x,int y,int w,int h,IntPtr parent,IntPtr menu,IntPtr instance,IntPtr param);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr window,IntPtr after,int x,int y,int w,int h,uint flags);
    [DllImport("user32.dll")] public static extern bool DestroyWindow(IntPtr window);
    public static int[][] Monitors() {
        var result = new List<int[]>();
        EnumDisplayMonitors(IntPtr.Zero,IntPtr.Zero,delegate(IntPtr m,IntPtr dc,ref Rect r,IntPtr p) {
            result.Add(new int[] {r.l,r.t,r.r-r.l,r.b-r.t}); return true;
        },IntPtr.Zero);
        return result.ToArray();
    }
}
'@

# Real compilation above is required: parsing .ps1 does not compile its C#.
foreach ($file in @((Get-ChildItem (Join-Path $root 'lib') -Filter '*.ps1')) + @((Get-Item (Join-Path $root 'tools/game-hand.ps1')))) {
    $tokens = $null; $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    Assert ($errors.Count -eq 0) "PowerShell parses: $($file.Name)"
}
$ping = Invoke-GpLine '{"id":1,"cmd":"ping","args":{}}'
Assert ($ping.ok -and $ping.data.engineVersion -eq 2) 'JSON dispatcher and version'
Assert ($ping.data.coordinateSystem -eq 'virtual-desktop-physical') 'physical coordinate contract'
Assert ($ping.data.engineRevision -match '^[a-f0-9]{64}$') 'engine source hash'

# Hidden native fixture: no activation or real application changes. Geometry is
# known before querying, including moves and a client-region touching the edge.
$window = [PositionTestWindow]::CreateWindowEx(0,'STATIC','DSH positioning fixture',2147483648,31,47,160,90,[IntPtr]::Zero,[IntPtr]::Zero,[IntPtr]::Zero,[IntPtr]::Zero)
Assert ($window -ne [IntPtr]::Zero) 'create native test window'
try {
    $info = Get-WindowInfo $window
    Assert ($info.clientX -eq 31 -and $info.clientY -eq 47 -and $info.clientW -eq 160 -and $info.clientH -eq 90) 'DPI aware client geometry is already physical'
    [void][PositionTestWindow]::SetWindowPos($window,[IntPtr]::Zero,61,73,200,120,0x14)
    $fresh = Resolve-CaptureRect @{hwnd=[int64]$window;region=@{x=190;y=100;w=30;h=40}}
    Assert ($fresh.x -eq 251 -and $fresh.y -eq 173 -and $fresh.w -eq 10 -and $fresh.h -eq 20) 'moved/resized window geometry refreshed; region clips to client intersection'
    Throws { Resolve-CaptureRect @{hwnd=[int64]$window;region=@{x=200;y=0;w=10;h=10}} } 'region past client edge is rejected'
    foreach ($monitor in [PositionTestWindow]::Monitors()) {
        [void][PositionTestWindow]::SetWindowPos($window,[IntPtr]::Zero,($monitor[0]+31),($monitor[1]+47),160,90,0x14)
        $moved = Get-WindowInfo $window
        Assert ($moved.clientX -eq ($monitor[0]+31) -and $moved.clientY -eq ($monitor[1]+47) -and $moved.clientW -eq 160 -and $moved.clientH -eq 90) 'same physical window dimensions on each monitor with mixed DPI'
    }
} finally { [void][PositionTestWindow]::DestroyWindow($window) }
Throws { Get-WindowInfo $window } 'closed window fails explicitly'

# Every topology uses the same normalization, including negative origins and
# the very first/last pixel. Decode as the Windows 16-bit pixel bucket.
foreach ($axis in @(@(0,1920), @(0,2560), @(-1920,4480), @(-1080,2520), @(0,4480))) {
    $origin = $axis[0]; $size = $axis[1]
    foreach ($value in @($origin, ($origin+1), ($origin+[int]($size/2)), ($origin+$size-2), ($origin+$size-1))) {
        $normalized = [Gp]::NormalizeAbsolute($value,$origin,$size)
        $decoded = $origin + [int][Math]::Floor($normalized * $size / 65536.0)
        Assert ([Math]::Abs($decoded-$value) -le 1) "normalize $value in $origin/$size"
    }
}
Throws { [Gp]::NormalizeAbsolute(-1921,-1920,4480) } 'reject out-of-desktop points'

$tpl = New-Object Drawing.Bitmap(23,17)
$rng = New-Object Random(42)
for ($y=0; $y -lt $tpl.Height; $y++) {
    for ($x=0; $x -lt $tpl.Width; $x++) { $tpl.SetPixel($x,$y,[Drawing.Color]::FromArgb($rng.Next(256),$rng.Next(256),$rng.Next(256))) }
}
$canvas = New-Object Drawing.Bitmap(192,108)
$g = [Drawing.Graphics]::FromImage($canvas)
$g.Clear([Drawing.Color]::FromArgb(30,35,40))
$g.DrawImageUnscaled($tpl,0,0); $g.DrawImageUnscaled($tpl,79,45); $g.DrawImageUnscaled($tpl,169,91)
$g.Dispose()
$matches = @([GpMatcher]::Find($canvas,$tpl,0.99,10))
Assert ($matches.Count -eq 3) 'all repeated targets; no duplicate overlapping matches'
foreach ($point in @(@(0,0),@(79,45),@(169,91))) {
    Assert (@($matches | Where-Object { $_.x -eq $point[0] -and $_.y -eq $point[1] -and $_.score -eq 1 }).Count -eq 1) 'exact match at edge or centre'
}
Assert (@([GpMatcher]::Find($canvas,$tpl,1,1)).Count -eq 1) 'threshold=1 and maxResults'
$blank = New-Object Drawing.Bitmap(60,40)
Assert (@([GpMatcher]::Find($blank,$tpl,0.9,5)).Count -eq 0) 'no match returns empty array'
Throws { [GpMatcher]::Find($canvas,$blank,0.9,5) } 'flat template rejected'
Throws { [GpMatcher]::Find($canvas,$tpl,0,5) } 'threshold validated'

# Keep the raw snapshot immutable even when a preview has grid/scale. A fake
# desktop capture lets the whole record/find protocol be tested offline.
$rawPath = Join-Path $testDir 'raw.png'
$canvas.Save($rawPath,[Drawing.Imaging.ImageFormat]::Png)
$snapshot = @{ shotId='fixture'; hwnd=123; rawPath=$rawPath; source=@{x=-1700;y=-900;w=192;h=108}; client=@{x=-1730;y=-920;w=300;h=200} }
Register-PositionShot $snapshot
$record = Invoke-PositionFind @{hwnd=123;template='test-enter';record=@{shotId='fixture';region=@{x=109;y=65;w=23;h=17}}}
Assert ($record.mode -eq 'record' -and (Test-Path $record.path)) 'record crop from exact raw screenshot with client and screen offsets'
$saved = [Drawing.Bitmap]::FromFile($record.path)
Assert ($saved.GetPixel(0,0).ToArgb() -eq $tpl.GetPixel(0,0).ToArgb()) 'saved template uses raw pixels'
$saved.Dispose()
Throws { Invoke-PositionFind @{hwnd=123;template='test-enter';record=@{shotId='fixture';region=@{x=109;y=65;w=23;h=17}}} } 'record refuses overwrite'
Throws { Invoke-PositionFind @{hwnd=456;template='wrong';record=@{shotId='fixture';region=@{x=109;y=65;w=23;h=17}}} } 'record rejects different window'
Throws { Get-TemplatePath '../escape' $true } 'template names cannot escape store'
Throws { Invoke-PositionFind @{hwnd=123;template='stale';record=@{shotId='expired';region=@{x=0;y=0;w=23;h=17}}} } 'expired snapshot explicit error'

$script:OriginalCapture = ${function:Capture-Frame}
$script:OriginalResolve = ${function:Resolve-CaptureRect}
function Capture-Frame { return @{path=$rawPath;source=$snapshot.source} }
function Resolve-CaptureRect { return @{client=$snapshot.client} }
$found = Invoke-GpLine '{"id":2,"cmd":"find","args":{"hwnd":123,"template":"test-enter","threshold":0.99}}'
Assert $found.ok 'find JSON protocol'
Assert (@($found.data.matches).Count -eq 3) 'find protocol returns matches array'
$middle = $found.data.matches | Where-Object { $_.x -eq -1621 -and $_.y -eq -855 }
Assert ($middle.center.x -eq -1610 -and $middle.center.y -eq -847) 'negative screen bounds and clickable integer centre'
Set-Item Function:Capture-Frame $script:OriginalCapture
Set-Item Function:Resolve-CaptureRect $script:OriginalResolve

# Real geometry/capture smoke test, no foreground activation or game input.
$desktop = Get-DesktopRect
Assert ($desktop.w -gt 0 -and $desktop.h -gt 0) 'live desktop geometry'
$shot = Capture-Frame 0 0 101 79 0.5 $true $true
Assert ($shot.source.w -eq 101 -and $shot.w -eq 50 -and $shot.h -eq 40) 'odd-sized capture reports actual rounded X/Y scale'
Assert ($shot.scaleX -ne $shot.scaleY) 'independent scale factors after rounding'
Assert (Test-Path $shot.rawPath) 'unscaled source kept for recording'
$liveRaw = [Drawing.Bitmap]::FromFile($shot.rawPath)
Assert ($liveRaw.Width -eq 101 -and $liveRaw.Height -eq 79) 'raw source preserves physical resolution'
$liveRaw.Dispose()
Throws { Capture-Frame ($desktop.x-$desktop.w-10) $desktop.y 5 5 1 } 'off-desktop capture rejects empty intersection'
$clipped = Capture-Frame ($desktop.x-10) $desktop.y 30 20 1
Assert ($clipped.source.x -eq $desktop.x -and $clipped.source.w -eq 20) 'negative edge clipping preserves intersection'

# Benchmark outside QTE hot path. This is a measurement, not an unrealistic
# universal millisecond guarantee for arbitrary template/image combinations.
$large = New-Object Drawing.Bitmap(1920,1080)
$g = [Drawing.Graphics]::FromImage($large)
$g.Clear([Drawing.Color]::FromArgb(30,35,40)); $g.DrawImageUnscaled($tpl,1499,901); $g.Dispose()
$watch = [Diagnostics.Stopwatch]::StartNew()
$bench = @([GpMatcher]::Find($large,$tpl,0.9,5))
Assert (@($bench | Where-Object {$_.x -eq 1499 -and $_.y -eq 901}).Count -eq 1) '1080p exhaustive scan finds off-grid target'
Write-Output "1080p matcher: $($watch.ElapsedMilliseconds) ms, template 23x17, threshold .9"

if ($CursorCheck) {
    # Deliberately opt-in: moves the cursor, never clicks, restores in finally.
    $before = New-Object Gp+POINT
    Assert ([Gp]::GetCursorPos([ref]$before)) 'read original cursor'
    try {
      foreach ($monitor in [PositionTestWindow]::Monitors()) {
        $left=$monitor[0]; $top=$monitor[1]; $width=$monitor[2]; $height=$monitor[3]
        Write-Output "monitor ($left,$top) ${width}x${height} physical pixels"
        foreach ($point in @(@(($left+8),($top+8)),@(($left+$width-9),($top+8)),@(($left+8),($top+$height-9)),@(($left+$width-9),($top+$height-9)),@(($left+[int]($width/2)),($top+[int]($height/2))))) {
            [Gp]::MouseMoveAbs($point[0],$point[1]); Start-Sleep -Milliseconds 50
            $actual = New-Object Gp+POINT
            Assert ([Gp]::GetCursorPos([ref]$actual)) 'read moved cursor'
            $errorPx = [Math]::Max([Math]::Abs($actual.X-$point[0]),[Math]::Abs($actual.Y-$point[1]))
            Write-Output "cursor ($($point[0]),$($point[1])) -> ($($actual.X),$($actual.Y)), error=$errorPx px"
            Assert ($errorPx -le 2) 'live cursor error <=2px'
        }
      }
    } finally { [Gp]::MouseMoveAbs($before.X,$before.Y) }
}
$large.Dispose(); $blank.Dispose(); $canvas.Dispose(); $tpl.Dispose()
Write-Output "PASS: $checks PowerShell/C# checks; fixture directory: $testDir"
