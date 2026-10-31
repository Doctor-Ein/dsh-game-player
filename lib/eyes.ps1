<#
  eyes.ps1 - 眼：截图、宫格合成、探针（看一小块）。不按键、不等待。

  依赖方向：只能往下用，不能往上调（eyes 永远不碰 run）。
  本文件由 lib/helper.ps1 按固定顺序 dot-source；单独执行没有意义。
#>

# ---------------------------------------------------------------- 工具函数

$script:TmpDir = Join-Path $env:TEMP 'dsh-game-player'
if (-not (Test-Path $script:TmpDir)) { New-Item -ItemType Directory -Path $script:TmpDir -Force | Out-Null }
$script:FrameSeq = 0


function Capture-Frame($x, $y, $w, $h, $scale) {
    if ($w -le 0 -or $h -le 0) { throw "bad capture size ${w}x${h}" }
    # 屏幕尺寸走 Win32，不用 System.Windows.Forms —— 那个程序集在 scriptblock 加载
    # 上下文里拿不到类型（[System.Windows.Forms.Screen] 解析失败），没必要为它留依赖。
    $swW = [Gp]::GetSystemMetrics(0)
    $swH = [Gp]::GetSystemMetrics(1)
    if ($x -lt 0) { $x = 0 }
    if ($y -lt 0) { $y = 0 }
    if (($x + $w) -gt $swW) { $w = [Math]::Max(8, $swW - $x) }
    if (($y + $h) -gt $swH) { $h = [Math]::Max(8, $swH - $y) }
    $bmp = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size($w, $h)))
    } finally {
        $g.Dispose()
    }
    if ($scale -and $scale -lt 1) {
        $nw = [int][Math]::Max(1, [Math]::Round($w * $scale))
        $nh = [int][Math]::Max(1, [Math]::Round($h * $scale))
        $small = New-Object System.Drawing.Bitmap($nw, $nh, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
        $g2 = [System.Drawing.Graphics]::FromImage($small)
        $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g2.DrawImage($bmp, 0, 0, $nw, $nh)
        $g2.Dispose()
        $bmp.Dispose()
        $bmp = $small
    }
    $script:FrameSeq++
    $path = Join-Path $script:TmpDir ("f{0:D5}-{1}.png" -f $script:FrameSeq, [int](Get-Random -Maximum 99999))
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $res = @{ path = $path; w = $bmp.Width; h = $bmp.Height }
    $bmp.Dispose()
    return $res
}

function Build-Sheet($paths, $cols, $cellW, $labels) {
    if (-not $paths -or $paths.Count -eq 0) { throw 'no frames to compose' }
    if (-not $cols -or $cols -lt 1) { $cols = [int][Math]::Ceiling([Math]::Sqrt($paths.Count)) }
    if (-not $cellW) { $cellW = 640 }
    $first = [System.Drawing.Image]::FromFile($paths[0])
    $aspect = $first.Height / $first.Width
    $first.Dispose()
    $cellH = [int][Math]::Round($cellW * $aspect)
    $rows = [int][Math]::Ceiling($paths.Count / $cols)
    $sheet = New-Object System.Drawing.Bitmap(($cellW * $cols), ($cellH * $rows), [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $g = [System.Drawing.Graphics]::FromImage($sheet)
    $g.Clear([System.Drawing.Color]::FromArgb(18, 18, 22))
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $font = New-Object System.Drawing.Font('Consolas', [float]([Math]::Max(11, $cellW / 34)), [System.Drawing.FontStyle]::Bold)
    $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 235, 220))
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(90, 255, 255, 255), 1)
    for ($i = 0; $i -lt $paths.Count; $i++) {
        $c = $i % $cols
        $r = [int][Math]::Floor($i / $cols)
        $x = $c * $cellW
        $y = $r * $cellH
        try {
            $img = [System.Drawing.Image]::FromFile($paths[$i])
            $g.DrawImage($img, (New-Object System.Drawing.Rectangle($x, $y, $cellW, $cellH)))
            $img.Dispose()
        } catch { }
        $g.DrawRectangle($pen, $x, $y, ($cellW - 1), ($cellH - 1))
        $label = if ($labels -and $labels.Count -gt $i) { $labels[$i] } else { "$($i + 1)" }
        $g.FillRectangle((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(190, 0, 0, 0))), $x, $y, ([Math]::Max(38, 22 + $label.Length * ($cellW / 60))), ([int]($cellW / 16)))
        $g.DrawString($label, $font, $brush, ([float]($x + 4)), ([float]($y + 2)))
    }
    $g.Dispose()
    $script:FrameSeq++
    $path = Join-Path $script:TmpDir ("sheet{0:D5}-{1}.png" -f $script:FrameSeq, [int](Get-Random -Maximum 99999))
    $sheet.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $res = @{ path = $path; w = $sheet.Width; h = $sheet.Height; cols = $cols; rows = $rows }
    $sheet.Dispose()
    return $res
}

# ---------------------------------------------------------------- 探针（等信号）
#
# 为什么放在这一侧：QTE 窗口只有 ~1.2 秒，而模型一次往返要几秒。
# 所以"看见什么就按什么"这个判断必须在本地做成毫秒级的轮询，
# 模型只负责说"从这一刻起盯着 qte 这个探针，最多等 1200ms，命中就点左键"。
#
# 探针 = 区域 + 颜色规则 + 最小命中像素数。颜色比图形识别稳、也快得多。

$script:ColorRules = @{
    # ZZZ 那个 QTE 圈的青蓝色：亮、偏绿蓝，红通道低
    cyan   = @{ rMin = 60; rMax = 170; gMin = 150; gMax = 240; bMin = 190; bMax = 255 }
    red    = @{ rMin = 170; rMax = 255; gMin = 0; gMax = 90; bMin = 0; bMax = 90 }
    yellow = @{ rMin = 190; rMax = 255; gMin = 150; gMax = 230; bMin = 0; bMax = 110 }
    white  = @{ rMin = 225; rMax = 255; gMin = 225; gMax = 255; bMin = 225; bMax = 255 }
}

# 命名探针。region 是**窗口客户区的比例**（0-1），换分辨率不用改。
# stride 决定采样密度：实测 stride=3 每次约 51ms、stride=6 约 19ms。
# QTE 窗口约 1.2 秒，取 5 足够（每 40ms 能查一次）。
$script:Probes = @{
    'qte'       = @{ region = @{ x = 0.60; y = 0.30; w = 0.19; h = 0.30 }; color = 'cyan'; minPixels = 30; stride = 5 }
    'qte_right' = @{ region = @{ x = 0.60; y = 0.30; w = 0.19; h = 0.30 }; color = 'red'; minPixels = 30; stride = 5 }
}

function Get-ColorRule($color) {
    if ($null -eq $color) { return $script:ColorRules['cyan'] }
    if ($color -is [string]) {
        $k = $color.ToLowerInvariant()
        if (-not $script:ColorRules.ContainsKey($k)) { throw "unknown color preset: $color" }
        return $script:ColorRules[$k]
    }
    return $color   # 显式 { rMin, rMax, gMin, gMax, bMin, bMax }
}

function Resolve-ProbeBox($probe, $win) {
    $spec = $null
    if ($probe -is [string]) {
        $k = $probe.ToLowerInvariant()
        if (-not $script:Probes.ContainsKey($k)) { throw "unknown probe: $probe" }
        $spec = $script:Probes[$k]
    } else {
        $spec = $probe
    }

    $r = $spec.region
    if ($null -eq $r) { throw 'probe needs a region' }

    # 没有窗口矩形时（比如离线标定），比例坐标按整块屏幕算。
    if (-not $win) {
        $win = @{ x = 0; y = 0; w = [Gp]::GetSystemMetrics(0); h = [Gp]::GetSystemMetrics(1) }
    }

    if ([double]$r.w -le 1 -and [double]$r.h -le 1 -and [double]$r.x -le 1 -and [double]$r.y -le 1) {
        # 比例 -> 像素
        $x = $win.x + [int][Math]::Round([double]$r.x * $win.w)
        $y = $win.y + [int][Math]::Round([double]$r.y * $win.h)
        $w = [int][Math]::Round([double]$r.w * $win.w)
        $h = [int][Math]::Round([double]$r.h * $win.h)
    } else {
        $x = [int]$r.x; $y = [int]$r.y; $w = [int]$r.w; $h = [int]$r.h
    }
    return @{
        x = $x; y = $y; w = $w; h = $h
        rule = (Get-ColorRule $spec.color)
        minPixels = if ($spec.minPixels) { [int]$spec.minPixels } else { 60 }
        stride = if ($spec.stride) { [int]$spec.stride } else { 3 }
    }
}

# ---------------- QTE 空心圆环检测（C# 实现，判据见 tools/qte_detect.py） ----------------
#
# 为什么不在 PowerShell 里扫：全屏 2560x1440 用 GetPixel 逐点要 400ms+，
# C# 里走 LockBits + 数组扫描是 3-5ms。这几毫秒直接决定能不能 40ms 轮询。

function Get-BitmapBytes($bmp) {
    $rect = New-Object System.Drawing.Rectangle(0, 0, $bmp.Width, $bmp.Height)
    $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
                          [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $len = $data.Stride * $data.Height
        $buf = New-Object byte[] $len
        [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $buf, 0, $len)
        return @{ bytes = $buf; w = $bmp.Width; h = $bmp.Height; stride = $data.Stride }
    } finally {
        $bmp.UnlockBits($data)
    }
}

function ConvertFrom-QteResult([string]$raw, [int]$w, [int]$h) {
    if ($raw -eq '0' -or -not $raw) { return @{ hit = $false; count = 0; bbox = $null } }
    $p = $raw.Split(';')
    $cx = [double]$p[1]; $cy = [double]$p[2]
    return @{
        hit    = $true
        count  = [int]$p[3]
        fill   = [double]$p[4]
        aspect = [double]$p[5]
        cx     = $cx
        cy     = $cy
        bbox   = @{ x = [int]($cx * $w); y = [int]($cy * $h) }
    }
}

# 采集带：只截画面纵向 10%~78% 那一条。
# 理由：QTE 环不会出现在最上/最下，少截 32% 的行，CopyFromScreen 从 20ms 降到约 12ms；
# 反击 QTE 的窗口很短，这 8ms 直接算在反应时间里。
$script:QteBandTop = 0.10
$script:QteBandHeight = 0.68

function Test-QteRing($win) {
    if (-not $win) { return @{ hit = $false; count = 0; bbox = $null; err = 'no window rect' } }
    $w = [int]$win.w; $full = [int]$win.h
    if ($w -lt 8 -or $full -lt 8) { return @{ hit = $false; count = 0; bbox = $null } }
    $top = [int][Math]::Round($full * $script:QteBandTop)
    $h = [int][Math]::Round($full * $script:QteBandHeight)
    $bmp = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.CopyFromScreen([int]$win.x, ([int]$win.y + $top), 0, 0, (New-Object System.Drawing.Size($w, $h)))
    } finally { $g.Dispose() }
    $shot = Get-BitmapBytes $bmp
    $bmp.Dispose()
    $raw = [Gp]::ScanQte($shot.bytes, $shot.w, $shot.h, $shot.stride)
    $res = ConvertFrom-QteResult $raw $shot.w $shot.h
    if ($res.hit) {
        # cy 是"带内比例"，换回整窗比例，方便上层对着截图看位置
        $res.cy = $script:QteBandTop + $res.cy * $script:QteBandHeight
        $res.bbox = @{ x = [int]($res.cx * $w); y = [int]($res.cy * $full) }
    }
    return $res
}

# 离线回归用：拿一张 PNG 跑同一套判据（C# 版必须和 Python 版结论一致）
function Test-QteImage([string]$path) {
    $src = [System.Drawing.Bitmap]::FromFile($path)
    try { $w = $src.Width; $h = $src.Height } finally { }
    $bmp = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.DrawImage($src, 0, 0, $w, $h)
    $g.Dispose()
    $src.Dispose()
    $shot = Get-BitmapBytes $bmp
    $bmp.Dispose()
    $raw = [Gp]::ScanQte($shot.bytes, $shot.w, $shot.h, $shot.stride)
    return (ConvertFrom-QteResult $raw $shot.w $shot.h)
}
# ---------------- 反击 QTE：固定采样点 ----------------
#
# 反击 QTE 的图标位置固定（实测圆心 0.6922, 0.4993），形状固定。
# 所以不做任何图像扫描：直接在这块小方框里读 26 个点的颜色，够了就发右键。
# 每个点自带期望颜色（从真实截图里自动提取，不是手填的）。
#
# 为什么这样可靠：进行中环是青色（G≈252, R≈118, B≈243）；MISS 后变灰（R≈G≈B），
# 灰像素在这三个通道上的差会和期望值差很远，自然不命中。

$script:CounterCenter = @{ cx = 0.6922; cy = 0.4993 }
$script:CounterBoxSide = 0.165      # 采集方框边长（按画面高度）
$script:CounterTolerance = 70       # |dR|+|dG|+|dB| 的上限
$script:CounterRatio = 0.80         # 命中比例（26 × 0.8 ≈ 21 个点）

$script:CounterPattern = @(
    @{ dx = 0.0423; dy = -0.0007; r = 122; g = 252; b = 242 }
    @{ dx = 0.0423; dy = 0.0111; r = 121; g = 253; b = 242 }
    @{ dx = 0.0368; dy = 0.0236; r = 120; g = 255; b = 240 }
    @{ dx = 0.0278; dy = 0.0354; r = 119; g = 250; b = 244 }
    @{ dx = 0.0125; dy = 0.0431; r = 119; g = 255; b = 244 }
    @{ dx = -0.0000; dy = 0.0451; r = 126; g = 252; b = 241 }
    @{ dx = -0.0139; dy = 0.0444; r = 118; g = 253; b = 239 }
    @{ dx = -0.0257; dy = 0.0382; r = 118; g = 252; b = 245 }
    @{ dx = -0.0382; dy = 0.0278; r = 121; g = 255; b = 242 }
    @{ dx = -0.0445; dy = 0.0153; r = 118; g = 254; b = 240 }
    @{ dx = -0.0472; dy = -0.0014; r = 121; g = 250; b = 245 }
    @{ dx = -0.0431; dy = -0.0160; r = 116; g = 253; b = 243 }
    @{ dx = -0.0375; dy = -0.0292; r = 118; g = 252; b = 241 }
    @{ dx = -0.0264; dy = -0.0375; r = 117; g = 250; b = 245 }
    @{ dx = -0.0146; dy = -0.0417; r = 117; g = 252; b = 246 }
    @{ dx = -0.0014; dy = -0.0451; r = 118; g = 249; b = 243 }
    @{ dx = 0.0118; dy = -0.0424; r = 118; g = 255; b = 247 }
    @{ dx = 0.0257; dy = -0.0361; r = 118; g = 252; b = 245 }
    @{ dx = 0.0354; dy = -0.0243; r = 116; g = 253; b = 243 }
    @{ dx = 0.0423; dy = -0.0146; r = 118; g = 252; b = 243 }
    @{ dx = -0.0146; dy = -0.0146; r = 125; g = 249; b = 241 }
    @{ dx = -0.0167; dy = 0.0160; r = 131; g = 250; b = 246 }
    @{ dx = 0.0034; dy = -0.0167; r = 133; g = 213; b = 204 }
    @{ dx = 0.0021; dy = 0.0160; r = 158; g = 244; b = 233 }
    @{ dx = 0.0201; dy = -0.0146; r = 139; g = 246; b = 238 }
    @{ dx = 0.0194; dy = 0.0132; r = 143; g = 244; b = 236 }
)

# 在一块已经截好的位图上数命中点。offBmp 允许把"整窗截图"当成坐标系用（离线回归）。
# ---------------- 第 2 阶段：内圈字形模板分类 ----------------
#
# 第 1 阶段（青色采样点）回答"这里有没有 QTE"；
# 第 2 阶段回答"它是哪一种"——只看内部字形，和外圈辉光/倒计时无关。
# 模板由 tools/gen_glyph_tpl.py 从 2560 原生截图生成，48x48 灰度。

$script:GlyphN = 48
$script:GlyphHalfNorm = 0.0235      # 裁剪半径 = 0.0235 x 画面高
$script:GlyphMinNcc = 0.70          # 自己的字形模板至少要有这个相似度
$script:GlyphTemplates = @{}

foreach ($__n in 'counter', 'flag') {
    $__p = Join-Path $PSScriptRoot ("..\tools\tpl3-$__n.png")
    if (Test-Path $__p) {
        $__bmp = [System.Drawing.Bitmap]::FromFile((Resolve-Path $__p).Path)
        try {
            $__arr = New-Object byte[] ($script:GlyphN * $script:GlyphN)
            for ($__y = 0; $__y -lt $script:GlyphN; $__y++) {
                for ($__x = 0; $__x -lt $script:GlyphN; $__x++) {
                    $__c = $__bmp.GetPixel($__x, $__y)
                    $__arr[$__y * $script:GlyphN + $__x] = [byte][Math]::Round(0.299 * $__c.R + 0.587 * $__c.G + 0.114 * $__c.B)
                }
            }
            $script:GlyphTemplates[$__n] = $__arr
            [Console]::Error.WriteLine("glyph template loaded: $__n")
        } finally { $__bmp.Dispose() }
    } else {
        [Console]::Error.WriteLine("glyph template MISSING: $__p")
    }
}

function Get-GlyphScore($bmp, [int]$cx, [int]$cy, [int]$frameH) {
    $res = @{ counter = -1.0; flag = -1.0 }
    if ($script:GlyphTemplates.Count -eq 0) { return $res }
    $shot = Get-BitmapBytes $bmp
    $half = $script:GlyphHalfNorm * $frameH
    foreach ($k in $script:GlyphTemplates.Keys) {
        $res[$k] = [Gp]::MatchGlyph($shot.bytes, $shot.w, $shot.h, $shot.stride, $cx, $cy, $half, $script:GlyphTemplates[$k], $script:GlyphN, 2)
    }
    return $res
}
function Measure-CounterPattern($bmp, [int]$offsetX, [int]$offsetY, [int]$frameH) {
    $hit = 0
    $total = $script:CounterPattern.Count
    $tol = $script:CounterTolerance
    foreach ($p in $script:CounterPattern) {
        $x = $offsetX + [int][Math]::Round($p.dx * $frameH)
        $y = $offsetY + [int][Math]::Round($p.dy * $frameH)
        if ($x -lt 0 -or $y -lt 0 -or $x -ge $bmp.Width -or $y -ge $bmp.Height) { continue }
        $c = $bmp.GetPixel($x, $y)
        $d = [Math]::Abs($c.R - $p.r) + [Math]::Abs($c.G - $p.g) + [Math]::Abs($c.B - $p.b)
        if ($d -le $tol) { $hit++ }
    }
    $ratio = if ($total -gt 0) { $hit / [double]$total } else { 0 }
    $glyph = Get-GlyphScore $bmp $offsetX $offsetY $frameH
    $ncc = [double]$glyph['counter']
    return @{
        hit    = (($ratio -ge $script:CounterRatio) -and ($ncc -ge $script:GlyphMinNcc))
        count  = $hit
        total  = $total
        ratio  = [Math]::Round($ratio, 2)
        ncc    = [Math]::Round($ncc, 2)
        bbox   = $null
    }
}

# 在线：截图标所在的小方框，数点
function Test-CounterQte($win) {
    if (-not $win) { return @{ hit = $false; count = 0; total = 0; ratio = 0; bbox = $null } }
    $frameH = [int]$win.h
    $side = [int][Math]::Round($frameH * $script:CounterBoxSide)
    $cx = [int][Math]::Round($win.x + $win.w * $script:CounterCenter.cx)
    $cy = [int][Math]::Round($win.y + $frameH * $script:CounterCenter.cy)
    $left = $cx - [int]($side / 2)
    $top = $cy - [int]($side / 2)
    $bmp = New-Object System.Drawing.Bitmap($side, $side, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try { $g.CopyFromScreen($left, $top, 0, 0, (New-Object System.Drawing.Size($side, $side))) }
    finally { $g.Dispose() }
    $res = Measure-CounterPattern $bmp ($side / 2) ($side / 2) $frameH
    $bmp.Dispose()
    return $res
}

# 离线：拿一张整窗截图跑同一套点（回归用，C# 版和 Python 版对账）
function Test-CounterImage([string]$path) {
    $bmp = [System.Drawing.Bitmap]::FromFile($path)
    try {
        $frameH = $bmp.Height
        $cx = [int][Math]::Round($bmp.Width * $script:CounterCenter.cx)
        $cy = [int][Math]::Round($bmp.Height * $script:CounterCenter.cy)
        return (Measure-CounterPattern $bmp $cx $cy $frameH)
    } finally { $bmp.Dispose() }
}
# ---------------- 主动 QTE（标记技能触发）：固定采样点 ----------------
#
# 和反击的区别：
#   · 环更小（半径 54px vs 65px，按 1440 高）
#   · 中心是"拳头"，不是 >>
#   · 环上点少放（12 个），重点放拳头轮廓（9 个）——两种 QTE 靠这个区分
# 颜色同为青色；提前太早点会变灰，同样不命中。

$script:FlagCenter = @{ cx = 0.6823; cy = 0.5099 }
$script:FlagBoxSide = 0.165
$script:FlagTolerance = 70
$script:FlagRatio = 0.80

$script:FlagPattern = @(
    @{ dx = 0.0384; dy = -0.0023; r = 111; g = 239; b = 246 }
    @{ dx = 0.0266; dy = 0.0137; r = 114; g = 242; b = 245 }
    @{ dx = 0.0182; dy = 0.0338; r = 121; g = 249; b = 250 }
    @{ dx = 0.0023; dy = 0.0304; r = 124; g = 245; b = 247 }
    @{ dx = -0.0207; dy = 0.0373; r = 122; g = 226; b = 255 }
    @{ dx = -0.0359; dy = 0.0200; r = 128; g = 223; b = 250 }
    @{ dx = -0.0380; dy = -0.0002; r = 149; g = 221; b = 251 }
    @{ dx = -0.0262; dy = -0.0141; r = 120; g = 240; b = 249 }
    @{ dx = -0.0193; dy = -0.0363; r = 111; g = 238; b = 254 }
    @{ dx = -0.0019; dy = -0.0328; r = 106; g = 234; b = 248 }
    @{ dx = 0.0175; dy = -0.0328; r = 107; g = 235; b = 248 }
    @{ dx = 0.0300; dy = -0.0196; r = 109; g = 237; b = 247 }
    @{ dx = 0.0238; dy = 0.0005; r = 112; g = 239; b = 246 }
    @{ dx = 0.0189; dy = 0.0116; r = 114; g = 241; b = 246 }
    @{ dx = 0.0106; dy = 0.0200; r = 116; g = 243; b = 246 }
    @{ dx = 0.0023; dy = 0.0200; r = 128; g = 223; b = 226 }
    @{ dx = -0.0207; dy = 0.0109; r = 124; g = 241; b = 246 }
    @{ dx = -0.0109; dy = -0.0189; r = 116; g = 231; b = 242 }
    @{ dx = 0.0009; dy = -0.0224; r = 108; g = 236; b = 247 }
    @{ dx = 0.0120; dy = -0.0217; r = 108; g = 237; b = 247 }
    @{ dx = 0.0196; dy = -0.0134; r = 120; g = 226; b = 235 }
)

function Measure-FlagPattern($bmp, [int]$offsetX, [int]$offsetY, [int]$frameH) {
    $hit = 0
    $total = $script:FlagPattern.Count
    $tol = $script:FlagTolerance
    foreach ($p in $script:FlagPattern) {
        $x = $offsetX + [int][Math]::Round($p.dx * $frameH)
        $y = $offsetY + [int][Math]::Round($p.dy * $frameH)
        if ($x -lt 0 -or $y -lt 0 -or $x -ge $bmp.Width -or $y -ge $bmp.Height) { continue }
        $c = $bmp.GetPixel($x, $y)
        $d = [Math]::Abs($c.R - $p.r) + [Math]::Abs($c.G - $p.g) + [Math]::Abs($c.B - $p.b)
        if ($d -le $tol) { $hit++ }
    }
    $ratio = if ($total -gt 0) { $hit / [double]$total } else { 0 }
    $glyph = Get-GlyphScore $bmp $offsetX $offsetY $frameH
    $ncc = [double]$glyph['flag']
    return @{
        hit   = (($ratio -ge $script:FlagRatio) -and ($ncc -ge $script:GlyphMinNcc))
        count = $hit
        total = $total
        ratio = [Math]::Round($ratio, 2)
        ncc   = [Math]::Round($ncc, 2)
        bbox  = $null
    }
}

function Test-FlagQte($win) {
    if (-not $win) { return @{ hit = $false; count = 0; total = 0; ratio = 0; bbox = $null } }
    $frameH = [int]$win.h
    $side = [int][Math]::Round($frameH * $script:FlagBoxSide)
    $cx = [int][Math]::Round($win.x + $win.w * $script:FlagCenter.cx)
    $cy = [int][Math]::Round($win.y + $frameH * $script:FlagCenter.cy)
    $left = $cx - [int]($side / 2)
    $top = $cy - [int]($side / 2)
    $bmp = New-Object System.Drawing.Bitmap($side, $side, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try { $g.CopyFromScreen($left, $top, 0, 0, (New-Object System.Drawing.Size($side, $side))) }
    finally { $g.Dispose() }
    $res = Measure-FlagPattern $bmp ($side / 2) ($side / 2) $frameH
    $bmp.Dispose()
    return $res
}

function Test-FlagImage([string]$path) {
    $bmp = [System.Drawing.Bitmap]::FromFile($path)
    try {
        return (Measure-FlagPattern $bmp ([int][Math]::Round($bmp.Width * $script:FlagCenter.cx)) ([int][Math]::Round($bmp.Height * $script:FlagCenter.cy)) $bmp.Height)
    } finally { $bmp.Dispose() }
}
function Test-Probe($probe, $win) {
    # 命名探针 qte / ring 走「空心圆环」检测器：全屏、与固定区域无关
    if ($probe -is [string] -and $probe -eq 'qte_counterattack') {
        return (Test-CounterQte $win)
    }
    if ($probe -is [string] -and $probe -eq 'qte_flag') {
        return (Test-FlagQte $win)
    }
    if ($probe -is [string] -and ($probe -eq 'qte' -or $probe -eq 'ring')) {
        return (Test-QteRing $win)
    }
    $b = Resolve-ProbeBox $probe $win
    $w = [Math]::Max(4, $b.w); $h = [Math]::Max(4, $b.h)
    $bmp = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.CopyFromScreen($b.x, $b.y, 0, 0, (New-Object System.Drawing.Size($w, $h)))
    } finally { $g.Dispose() }

    $rule = $b.rule
    $stride = [Math]::Max(1, $b.stride)
    $count = 0
    $minX = $w; $minY = $h; $maxX = -1; $maxY = -1
    for ($yy = 0; $yy -lt $h; $yy += $stride) {
        for ($xx = 0; $xx -lt $w; $xx += $stride) {
            $c = $bmp.GetPixel($xx, $yy)
            if ($c.R -ge $rule.rMin -and $c.R -le $rule.rMax -and
                $c.G -ge $rule.gMin -and $c.G -le $rule.gMax -and
                $c.B -ge $rule.bMin -and $c.B -le $rule.bMax) {
                $count++
                if ($xx -lt $minX) { $minX = $xx }
                if ($yy -lt $minY) { $minY = $yy }
                if ($xx -gt $maxX) { $maxX = $xx }
                if ($yy -gt $maxY) { $maxY = $yy }
            }
        }
    }
    $bmp.Dispose()
    return @{
        hit     = ($count -ge $b.minPixels)
        count   = $count
        minPixels = $b.minPixels
        box     = @{ x = $b.x; y = $b.y; w = $w; h = $h }
        bbox    = if ($maxX -ge 0) { @{ x = $b.x + $minX; y = $b.y + $minY; w = ($maxX - $minX + $stride); h = ($maxY - $minY + $stride) } } else { $null }
    }
}

