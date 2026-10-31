<#
  win32.ps1 - 最底层：Win32 P/Invoke 声明、编译，以及窗口查询。

  依赖方向：只能往下用，不能往上调（eyes 永远不碰 run）。
  本文件由 lib/helper.ps1 按固定顺序 dot-source；单独执行没有意义。
#>

# helper.ps1 - dsh-game-player 的常驻 Windows 助手。
#
# 为什么是常驻进程：每次 spawn powershell.exe 要 300-600 ms，Add-Type 编译 P/Invoke 又要 400 ms+。
# 编译一次、进程不退出，之后每条 cap ~40-90 ms、每条 input ~5 ms，才谈得上"按游戏速度出招"。
#
# 协议：stdin/stdout 各一行一个 JSON（UTF-8）。
#   请求  {"id":1,"cmd":"run","args":{...}}
#   响应  {"id":1,"ok":true,"data":{...}}  /  {"id":1,"ok":false,"error":"..."}
# stdout 只允许出现 JSON 行，任何调试输出都走 stderr。
#
# 只用公开的 Win32 API + GDI：屏幕像素 + SendInput。不碰游戏进程内存。

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$script:Out = [Console]::Out

Add-Type -AssemblyName System.Drawing

$cs = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class Gp {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] public struct HARDWAREINPUT { public uint uMsg; public ushort wParamL, wParamH; }
    [StructLayout(LayoutKind.Explicit)] public struct INPUTUNION {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
        [FieldOffset(0)] public HARDWAREINPUT hi;
    }
    [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public INPUTUNION u; }

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vk);
    [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint type);
    [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();

    public const uint INPUT_MOUSE = 0, INPUT_KEYBOARD = 1;
    public const uint ME_MOVE = 0x0001, ME_LEFTDOWN = 0x0002, ME_LEFTUP = 0x0004,
                      ME_RIGHTDOWN = 0x0008, ME_RIGHTUP = 0x0010, ME_MIDDLEDOWN = 0x0020,
                      ME_MIDDLEUP = 0x0040, ME_WHEEL = 0x0800, ME_ABSOLUTE = 0x8000;
    public const uint KE_EXTENDED = 0x0001, KE_KEYUP = 0x0002, KE_SCANCODE = 0x0008;

    static readonly int InputSize = Marshal.SizeOf(typeof(INPUT));

    static bool IsExtendedVk(ushort vk) {
        // 方向键 / 编辑键 / 小键盘除号 / NumLock：需要 EXTENDEDKEY，否则游戏读到的是小键盘。
        if (vk >= 0x21 && vk <= 0x2E) return true;   // PgUp..Delete, Home/End/Arrows
        if (vk == 0x90) return true;                 // NumLock
        if (vk == 0x6F) return true;                 // 小键盘 /
        return false;
    }

    public static void KeySend(ushort vk, bool up) {
        ushort scan = (ushort)(MapVirtualKey(vk, 0) & 0xFF);
        uint flags = KE_SCANCODE;
        if (up) flags |= KE_KEYUP;
        if (IsExtendedVk(vk)) flags |= KE_EXTENDED;
        var inp = new INPUT {
            type = INPUT_KEYBOARD,
            u = new INPUTUNION { ki = new KEYBDINPUT { wVk = 0, wScan = scan, dwFlags = flags, time = 0 } }
        };
        var arr = new INPUT[] { inp };
        SendInput(1, arr, InputSize);
    }

    public static void MouseMoveRel(int dx, int dy) {
        var inp = new INPUT {
            type = INPUT_MOUSE,
            u = new INPUTUNION { mi = new MOUSEINPUT { dx = dx, dy = dy, dwFlags = ME_MOVE } }
        };
        SendInput(1, new INPUT[] { inp }, InputSize);
    }

    public static void MouseMoveAbs(int x, int y) {
        int sw = GetSystemMetrics(0), sh = GetSystemMetrics(1);
        if (sw <= 1 || sh <= 1) return;
        int nx = (int)Math.Round(x * 65535.0 / (sw - 1));
        int ny = (int)Math.Round(y * 65535.0 / (sh - 1));
        var inp = new INPUT {
            type = INPUT_MOUSE,
            u = new INPUTUNION { mi = new MOUSEINPUT { dx = nx, dy = ny, dwFlags = ME_MOVE | ME_ABSOLUTE } }
        };
        SendInput(1, new INPUT[] { inp }, InputSize);
    }

    public static void MouseButton(uint flag, uint data = 0) {
        var inp = new INPUT {
            type = INPUT_MOUSE,
            u = new INPUTUNION { mi = new MOUSEINPUT { dx = 0, dy = 0, mouseData = data, dwFlags = flag } }
        };
        SendInput(1, new INPUT[] { inp }, InputSize);
    }

    public static void Wheel(int delta) {
        MouseButton(ME_WHEEL, (uint)delta);
    }

    public static bool IsDown(int vk) { return (GetAsyncKeyState(vk) & 0x8000) != 0; }

    // ---------------- QTE 空心圆环检测 ----------------
    // 判据与离线标定脚本 tools/qte_detect.py 一一对应（颜色 -> 4x4合并 -> 连通块 -> 几何）。
    // 输入：32bppArgb 像素数组；输出："0" 或 "1;cx;cy;area;fill;aspect"
    static bool PaleCyan(byte b, byte g, byte r) {
        // 近白青：R>=0.60 G>=0.90 B>=0.90  V>=0.88  S>=0.10  H 168..196
        if (r < 153 || g < 230 || b < 230) return false;
        int mx = Math.Max(r, Math.Max(g, b));
        int mn = Math.Min(r, Math.Min(g, b));
        int d = mx - mn;
        if (mx < 224) return false;
        if (d * 10 < mx) return false;
        double hh;
        if (mx == b) hh = 60.0 * ((r - g) / (double)d + 4.0);
        else if (mx == g) hh = 60.0 * ((b - r) / (double)d + 2.0);
        else hh = 60.0 * (((g - b) / (double)d) % 6.0);
        return hh >= 168.0 && hh <= 196.0;
    }

    public static string ScanQte(byte[] buf, int w, int h, int stride) {
        const int CELL = 4;
        int gw = w / CELL, gh = h / CELL;
        if (gw <= 2 || gh <= 2) return "0";
        bool[] cells = new bool[gw * gh];
        for (int gy = 0; gy < gh; gy++) {
            int rowBase = gy * CELL * stride;
            for (int gx = 0; gx < gw; gx++) {
                bool hitCell = false;
                for (int sy = 0; sy < CELL && !hitCell; sy += 2) {
                    int o = rowBase + sy * stride + gx * CELL * 4;
                    for (int sx = 0; sx < CELL; sx += 2) {
                        int p = o + sx * 4;
                        if (PaleCyan(buf[p], buf[p + 1], buf[p + 2])) { hitCell = true; break; }
                    }
                }
                cells[gy * gw + gx] = hitCell;
            }
        }
        bool[] seen = new bool[cells.Length];
        int[] stack = new int[cells.Length];
        for (int i = 0; i < cells.Length; i++) {
            if (!cells[i] || seen[i]) continue;
            int sp = 0; stack[sp++] = i; seen[i] = true;
            int area = 0, x0 = int.MaxValue, x1 = -1, y0 = int.MaxValue, y1 = -1;
            while (sp > 0) {
                int cur = stack[--sp];
                int cy2 = cur / gw, cx2 = cur - cy2 * gw;
                area++;
                if (cx2 < x0) x0 = cx2; if (cx2 > x1) x1 = cx2;
                if (cy2 < y0) y0 = cy2; if (cy2 > y1) y1 = cy2;
                if (cx2 > 0)      { int n = cur - 1;  if (cells[n] && !seen[n]) { seen[n] = true; stack[sp++] = n; } }
                if (cx2 < gw - 1) { int n = cur + 1;  if (cells[n] && !seen[n]) { seen[n] = true; stack[sp++] = n; } }
                if (cy2 > 0)      { int n = cur - gw; if (cells[n] && !seen[n]) { seen[n] = true; stack[sp++] = n; } }
                if (cy2 < gh - 1) { int n = cur + gw; if (cells[n] && !seen[n]) { seen[n] = true; stack[sp++] = n; } }
            }
            if (area < 20 || area > 1200) continue;   // 下限调低：环刚冒头就认，抢那 100-200ms
            int bw = x1 - x0 + 1, bh = y1 - y0 + 1;
            if (bw <= 1 || bh <= 1) continue;
            double fill = area / (double)(bw * bh);
            double aspect = bw / (double)bh;
            double cyNorm = (y0 + y1) / 2.0 / gh;
            if (cyNorm < 0.05 || cyNorm > 0.95) continue;   // 纵向由采集带控制，这里只挡掉极端情况
            if (aspect < 0.6 || aspect > 1.7) continue;
            if (fill < 0.05 || fill > 0.28) continue;
            double cx = (x0 + x1) / 2.0 / gw;
            return string.Format("1;{0:F3};{1:F3};{2};{3:F3};{4:F3}",
                                 cx, cyNorm, area, fill, aspect);
        }
        return "0";
    }
    // ---- 内圈字形匹配（模板分类）----
    // 把图标中心的一块按面积平均缩到 N x N 灰度，再和模板算归一化互相关。
    // 只在小范围(±search px)内搜索位置，抗 1-2px 抖动。
    public static double MatchGlyph(byte[] buf, int w, int h, int stride, double cx, double cy, double half, byte[] tplBytes, int n, int search) {
        double[] obs = new double[n * n];
        double[] tpl = new double[n * n];
        double tmean = 0, tstd = 0;
        for (int i = 0; i < n * n; i++) { tpl[i] = tplBytes[i]; tmean += tpl[i]; }
        tmean /= n * n;
        for (int i = 0; i < n * n; i++) { tpl[i] -= tmean; tstd += tpl[i] * tpl[i]; }
        tstd = System.Math.Sqrt(tstd / (n * n));
        if (tstd < 1e-6) return -1;
        for (int i = 0; i < n * n; i++) tpl[i] /= tstd;

        double best = -1;
        for (int oy = -search; oy <= search; oy++) {
            for (int ox = -search; ox <= search; ox++) {
                double mean = 0;
                int cnt = 0;
                for (int gy = 0; gy < n; gy++) {
                    for (int gx = 0; gx < n; gx++) {
                        // 该格在源图上的范围（面积平均）
                        double sx0 = cx + ox - half + (2.0 * half) * gx / n;
                        double sx1 = cx + ox - half + (2.0 * half) * (gx + 1) / n;
                        double sy0 = cy + oy - half + (2.0 * half) * gy / n;
                        double sy1 = cy + oy - half + (2.0 * half) * (gy + 1) / n;
                        int ix0 = (int)System.Math.Floor(sx0), ix1 = (int)System.Math.Ceiling(sx1);
                        int iy0 = (int)System.Math.Floor(sy0), iy1 = (int)System.Math.Ceiling(sy1);
                        if (ix0 < 0) ix0 = 0; if (iy0 < 0) iy0 = 0;
                        if (ix1 > w) ix1 = w; if (iy1 > h) iy1 = h;
                        double sum = 0; int c = 0;
                        for (int yy = iy0; yy < iy1; yy++) {
                            int rb = yy * stride;
                            for (int xx = ix0; xx < ix1; xx++) {
                                int p = rb + xx * 4;
                                // 亮度（粗略灰度）
                                sum += 0.114 * buf[p] + 0.587 * buf[p + 1] + 0.299 * buf[p + 2];
                                c++;
                            }
                        }
                        double v = (c > 0) ? sum / c : 0;
                        obs[gy * n + gx] = v;
                        mean += v;
                        cnt++;
                    }
                }
                if (cnt == 0) continue;
                mean /= cnt;
                double std = 0;
                for (int i = 0; i < n * n; i++) { obs[i] -= mean; std += obs[i] * obs[i]; }
                std = System.Math.Sqrt(std / (n * n));
                if (std < 1e-6) continue;
                double ncc = 0;
                for (int i = 0; i < n * n; i++) ncc += obs[i] * tpl[i];
                ncc /= (n * n * std);
                if (ncc > best) best = ncc;
            }
        }
        return best;
    }

    public static string[] Windows() { return null; } // 占位：窗口枚举在 PowerShell 侧做
}
'@

try {
    Add-Type -TypeDefinition $cs -ErrorAction Stop
} catch {
    [Console]::Error.WriteLine("Add-Type failed: $($_.Exception.Message)")
    throw
}

[void][Gp]::SetProcessDPIAware()


function Get-WindowInfo($proc) {
    $rect = New-Object Gp+RECT
    [void][Gp]::GetWindowRect($proc, [ref]$rect)
    $crect = New-Object Gp+RECT
    [void][Gp]::GetClientRect($proc, [ref]$crect)
    $origin = New-Object Gp+POINT
    $origin.X = 0; $origin.Y = 0
    [void][Gp]::ClientToScreen($proc, [ref]$origin)
    # 注意：变量名不能叫 $pid —— 那是 PowerShell 的自动只读变量，赋值会抛
    # "Cannot overwrite variable PID"，而回调里的 catch 会把它吞掉，表现就是
    # 「窗口枚举永远返回 0」。踩过一次，留着这条注释。
    $procId = 0
    [void][Gp]::GetWindowThreadProcessId($proc, [ref]$procId)
    $title = New-Object System.Text.StringBuilder 512
    [void][Gp]::GetWindowTextW($proc, $title, 512)
    $cls = New-Object System.Text.StringBuilder 256
    [void][Gp]::GetClassNameW($proc, $cls, 256)
    [pscustomobject]@{
        hwnd       = [int64]$proc
        title      = $title.ToString()
        cls        = $cls.ToString()
        pid        = $procId
        clientX    = $origin.X
        clientY    = $origin.Y
        clientW    = $crect.Right - $crect.Left
        clientH    = $crect.Bottom - $crect.Top
        winX       = $rect.Left
        winY       = $rect.Top
        winW       = $rect.Right - $rect.Left
        winH       = $rect.Bottom - $rect.Top
        minimized  = [bool][Gp]::IsIconic($proc)
        foreground = ([Gp]::GetForegroundWindow() -eq $proc)
    }
}

function Get-Windows($filter) {
    $found = New-Object System.Collections.ArrayList
    $cb = [Gp+EnumWindowsProc] {
        param($h, $l)
        try {
            if ([Gp]::IsWindowVisible($h)) {
                $t = New-Object System.Text.StringBuilder 512
                [void][Gp]::GetWindowTextW($h, $t, 512)
                $title = $t.ToString()
                if ($title -and $title.Trim().Length -gt 0) {
                    if (-not $filter -or $title -like "*$filter*") {
                        [void]$found.Add((Get-WindowInfo $h))
                    }
                }
            }
        } catch { }
        return $true
    }
    [void][Gp]::EnumWindows($cb, [IntPtr]::Zero)
    return $found
}

function Resolve-Hwnd($opt) {
    if ($opt.hwnd) { return [IntPtr][int64]$opt.hwnd }
    $needle = "$($opt.window)"
    if (-not $needle) { throw 'no window bound: pass hwnd or window title' }
    $ws = Get-Windows $needle
    if ($ws.Count -eq 0) { throw "no visible window matching '$needle'" }
    $exact = $ws | Where-Object { $_.title -eq $needle }
    if ($exact) { return [IntPtr][int64]($exact | Select-Object -First 1).hwnd }
    return [IntPtr][int64]($ws | Select-Object -First 1).hwnd
}

