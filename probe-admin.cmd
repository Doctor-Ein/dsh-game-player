@echo off
rem ASCII ONLY. Runs the input probe with administrator rights.
rem Right-click this file -> Run as administrator.
setlocal
set "HERE=%~dp0"
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%HERE%tools\_adm-probe.ps1"

echo.
echo Result file: %HERE%tools\probe-result.txt
echo Screenshots: %HERE%tools\probe-base.png / probe-f1.png / probe-esc.png / probe-w.png
pause
endlocal
