@echo off
rem ASCII ONLY (cmd.exe reads this as GBK; non-ASCII bytes break the parser).
rem Double-click: unblocks dsh-ops, sets CurrentUser policy, then runs the game-hand
rem selftest - everything is written to fix-shell.log next to this file.

setlocal
set "HERE=%~dp0"
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%HERE%tools\fix-shell.ps1"

echo.
echo Log written to: %HERE%fix-shell.log
pause
endlocal
