<# Snapshot-backed template recording and exact physical-pixel localization.
   This is separate from the timing-sensitive QTE detectors. #>
Add-Type -Path (Join-Path $PSScriptRoot 'matcher.cs') -ReferencedAssemblies System.Drawing
$script:PositionShots = @{}
$script:PositionOrder = New-Object System.Collections.Queue
$script:TemplateDir = Join-Path $script:TmpDir 'templates'

function Register-PositionShot($shot) {
    $script:PositionShots[$shot.shotId] = $shot
    $script:PositionOrder.Enqueue($shot.shotId)
    while ($script:PositionOrder.Count -gt 16) {
        $expiredId = $script:PositionOrder.Dequeue()
        $expired = $script:PositionShots[$expiredId]
        $script:PositionShots.Remove($expiredId)
        if ($expired.rawPath -and (Test-Path -LiteralPath $expired.rawPath)) {
            Remove-Item -LiteralPath $expired.rawPath -ErrorAction SilentlyContinue
        }
    }
}

function Get-TemplatePath([string]$name, [bool]$record) {
    if ($name -match '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$') {
        return (Join-Path $script:TemplateDir "$name.png")
    }
    if (-not $record -and $name -match '^(?:[a-zA-Z]:[\\/]|\\\\[^\\]+\\[^\\]+\\)' -and [System.IO.Path]::GetExtension($name) -ieq '.png') { return $name }
    throw 'template must be a name (letters, digits, _ or -, max 64) or an absolute PNG path for finding'
}

function Invoke-PositionFind($opt) {
    $path = Get-TemplatePath ([string]$opt.template) ([bool]$opt.record)
    if ($opt.record) {
        $shot = $script:PositionShots[[string]$opt.record.shotId]
        if (-not $shot -or -not (Test-Path -LiteralPath $shot.rawPath)) { throw 'shotId expired or from another hand process: take game_shot again' }
        if ([int64]$shot.hwnd -ne [int64]$opt.hwnd) { throw 'shotId belongs to another window' }
        $r = $opt.record.region
        foreach ($key in 'x','y','w','h') {
            if ($null -eq $r.$key -or [double]$r.$key -ne [Math]::Truncate([double]$r.$key)) { throw 'record.region requires integer client x,y,w,h' }
        }
        $x = [int]$r.x + $shot.client.x - $shot.source.x
        $y = [int]$r.y + $shot.client.y - $shot.source.y
        $w = [int]$r.w; $h = [int]$r.h
        if ($w -lt 3 -or $h -lt 3 -or $w -gt 512 -or $h -gt 512 -or $x -lt 0 -or $y -lt 0 -or ($x + $w) -gt $shot.source.w -or ($y + $h) -gt $shot.source.h) { throw 'template region must fit the original screenshot and be 3..512 physical pixels per side' }
        if (Test-Path -LiteralPath $path) { throw 'template already exists: use a new name' }
        $raw = [System.Drawing.Bitmap]::FromFile($shot.rawPath)
        try {
            $crop = $raw.Clone((New-Object System.Drawing.Rectangle($x,$y,$w,$h)), [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
            try {
                # Validate texture before committing a useless template.
                [void][GpMatcher]::Find($crop, $crop, 1, 1)
                if (-not (Test-Path -LiteralPath $script:TemplateDir)) { [void](New-Item -ItemType Directory -Path $script:TemplateDir -Force) }
                $crop.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
            } finally { $crop.Dispose() }
        } finally { $raw.Dispose() }
        return @{ mode = 'record'; template = $opt.template; path = $path; w = $w; h = $h; shotId = $shot.shotId; coordinateSystem = $script:CoordinateSystem }
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'template not found: record from a game_shot first, or pass an absolute PNG path' }
    $rect = Resolve-CaptureRect $opt
    $shot = Capture-Frame $rect.x $rect.y $rect.w $rect.h 1
    $threshold = if ($null -ne $opt.threshold) { [double]$opt.threshold } else { 0.9 }
    $max = if ($null -ne $opt.maxResults) { [int]$opt.maxResults } else { 5 }
    $image = [System.Drawing.Bitmap]::FromFile($shot.path)
    $template = [System.Drawing.Bitmap]::FromFile($path)
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $matches = @([GpMatcher]::Find($image, $template, $threshold, $max) | ForEach-Object {
            @{ x = $_.x + $shot.source.x; y = $_.y + $shot.source.y; w = $_.w; h = $_.h; score = [Math]::Round($_.score, 6);
               center = @{ x = $_.x + $shot.source.x + [int][Math]::Floor($_.w / 2); y = $_.y + $shot.source.y + [int][Math]::Floor($_.h / 2) } }
        })
        return @{ mode = 'find'; template = $opt.template; matches = $matches; region = $shot.source; client = $rect.client; threshold = $threshold; matchMs = $clock.ElapsedMilliseconds; coordinateSystem = $script:CoordinateSystem }
    } finally { $image.Dispose(); $template.Dispose() }
}
