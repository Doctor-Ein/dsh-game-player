$ErrorActionPreference = 'Stop'
# Simulated input backend: exercises real scheduling/click/abort logic without
# emitting a single keyboard or mouse event to the desktop.
Add-Type @'
using System;
using System.Collections.Generic;
public static class Gp {
    public const uint ME_LEFTUP=4, ME_LEFTDOWN=2, ME_RIGHTUP=16, ME_RIGHTDOWN=8, ME_MIDDLEUP=64, ME_MIDDLEDOWN=32;
    public static List<string> Events = new List<string>();
    public static DateTime AbortAt = DateTime.MaxValue;
    public static bool IsDown(int key) { return DateTime.UtcNow >= AbortAt; }
    public static IntPtr GetForegroundWindow() { return new IntPtr(42); }
    public static void KeySend(ushort key, bool up) { Events.Add("key:"+key+":"+up); }
    public static void MouseMoveAbs(int x,int y) { if(x==99999)throw new Exception("bad target"); Events.Add("move:"+x+":"+y); }
    public static void MouseMoveRel(int x,int y) { Events.Add("rel"); }
    public static void MouseButton(uint flag) { Events.Add("button:"+flag); }
    public static void Wheel(int delta) { Events.Add("wheel"); }
}
'@
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'lib/hands.ps1')
. (Join-Path $root 'lib/run.ps1')
function Get-WindowInfo { return @{clientX=-1920;clientY=0;clientW=1920;clientH=1080} }
$checks=0
function Assert($value,$label) { if(-not $value){throw "FAIL: $label"};$script:checks++ }
$r = Invoke-Run @{actions=@(@{t='mouse';a='click';x=-1800;y=250;ms=1});capture=@{enabled=$false};hwnd=42;requireForeground=$true}
Assert (-not $r.aborted) 'normal click completes'
Assert ([Gp]::Events[0] -eq 'move:-1800:250' -and [Gp]::Events[1] -eq 'button:2' -and [Gp]::Events[2] -eq 'button:4') 'click moves before down/up'
[Gp]::Events.Clear()
$r=Invoke-Run @{actions=@(@{t='mouse';a='abs';x=99999;y=0},@{t='mouse';a='click'});capture=@{enabled=$false}}
Assert ($r.aborted -and @($r.trace | Where-Object {$_.err}).Count -eq 1) 'failed move aborts block'
Assert (-not [Gp]::Events.Contains('button:2')) 'failed move never falls through to later click'

foreach($step in @(@{t='key';k='w';ms=1000;repeat=3;gap=1000},@{t='mouse';ms=1000;repeat=3;gap=1000},@{t='wait';ms=1000})) {
    [Gp]::Events.Clear(); [Gp]::AbortAt=[DateTime]::UtcNow.AddMilliseconds(60)
    $state=@{abortKey='F12';aborted=$false;trace=(New-Object Collections.ArrayList)}
    $watch=[Diagnostics.Stopwatch]::StartNew()
    Invoke-ThenSteps @($step) $state
    Assert ($state.aborted -and $watch.ElapsedMilliseconds -lt 250) 'F12 interrupts reflex hold/repeats/wait'
}
[Gp]::AbortAt=[DateTime]::MaxValue
[Gp]::Events.Clear()
function Test-Probe { return @{hit=$true;count=26} }
$r=Invoke-Run @{actions=@(@{t='waitfor';probe='qte_counterattack';then=@{t='mouse';btn='right';ms=1}});capture=@{enabled=$false}}
Assert (-not $r.aborted -and [Gp]::Events.Contains('button:8')) 'QTE hit still fires right click'
Assert (@($r.trace | Where-Object {$_.t -eq 'waitfor' -and $_.hit}).Count -eq 1) 'QTE evidence retained'
[Gp]::Events.Clear()
function Test-Probe { return @{hit=$false;count=0} }
$r=Invoke-Run @{actions=@(@{t='waitfor';timeoutMs=100;then=@{t='mouse';btn='right'}});capture=@{enabled=$false}}
Assert (-not [Gp]::Events.Contains('button:8')) 'QTE miss never clicks'
Write-Output "PASS: $checks simulated scheduler checks (no desktop input)"
