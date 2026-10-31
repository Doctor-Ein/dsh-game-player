@echo off
rem ASCII ONLY IN THIS FILE.
rem cmd.exe reads .cmd as the OEM codepage; non-ASCII bytes in comments shift the
rem parser and swallow following lines. Keep every byte ASCII.
rem
rem   start-gameplay.cmd            -> play (default), self-elevating via UAC
rem   start-gameplay.cmd selftest   -> capture one screenshot and exit
rem
rem Why admin: the game runs as administrator and Windows UIPI silently drops
rem SendInput from a lower-integrity process. Non-elevated = keys do nothing.
rem
rem Log: packages\dsh-game-player\game-hand.log

setlocal
set "HERE=%~dp0"
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"

rem fsutil needs admin -> errorlevel 1 means we are not elevated yet
fsutil dirty query %SystemDrive% >nul 2>&1
if errorlevel 1 goto elevate

if "%~1"=="" goto play
if /I "%~1"=="selftest" goto selftest
if /I "%~1"=="play" goto play
echo unknown argument: %~1
echo usage: start-gameplay.cmd [play^|selftest]
pause
goto end

:elevate
echo Asking Windows for administrator rights (UAC)...
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%HERE%tools\elevate.ps1"
if errorlevel 1 (
  echo.
  echo [elevation failed] see %HERE%elevate.log
  pause
)
goto end

:play
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%HERE%tools\game-hand.ps1"
if errorlevel 1 goto failed
goto end

:selftest
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%HERE%tools\game-hand.ps1" -SelfTest
if errorlevel 1 goto failed
goto end

:failed
echo.
echo [FAILED] exit code %errorlevel%. See: %HERE%game-hand.log
pause

:end
endlocal
