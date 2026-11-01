$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib/helper.ps1')
Out-Json @{hello=$true;pid=$PID;engineVersion=$script:EngineVersion;engineRevision=$script:EngineRevision;coordinateSystem=$script:CoordinateSystem}
while ($null -ne ($line = [Console]::In.ReadLine())) {
    $result = Invoke-GpLine $line
    if ($null -ne $result) { Out-Json $result }
}
