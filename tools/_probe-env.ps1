$env:GP_TEST_FLAG = '1'
$probe = 'if (-not $env:GP_TEST_FLAG) { Write-Output "LOOP-RAN" } else { Write-Output "SKIPPED" }'
. ([scriptblock]::Create($probe))
Write-Output ("flag=" + $env:GP_TEST_FLAG)
