@echo off
rem ===========================================================================
rem  DeepSeek Harness Web UI - auto-start launcher
rem  Boot entry: the Startup VBS written by deploy/windows/install.ps1 runs
rem  THIS file straight from the repo checkout (%~dp0 = <repo>\deploy\windows\)
rem  so a plain `git pull` on this machine ships the new boot logic - no
rem  copy/install step after the first install.ps1.
rem  1) Runs dsh-web-update.ps1: when a newer official dsh exists it ASKS the
rem     human (MessageBox), uninstalls conflicting plugins and upgrades on
rem     Yes - it never silently upgrades behind the user's back.
rem  2) Starts dsh web; the browser opens the authenticated token URL.
rem ===========================================================================
setlocal

set "PS1=%~dp0dsh-web-update.ps1"
set "LOG=%USERPROFILE%\.dsh\autostart-update.log"
set "DSH="

rem ---- resolve the official dsh launcher (logon PATH may lack it) ----
where dsh >nul 2>&1 && set "DSH=dsh"
if not defined DSH if exist "%ProgramFiles%\nodejs\dsh.cmd"  set "DSH=%ProgramFiles%\nodejs\dsh.cmd"
if not defined DSH if exist "%LOCALAPPDATA%\Programs\nodejs\dsh.cmd" set "DSH=%LOCALAPPDATA%\Programs\nodejs\dsh.cmd"
if not defined DSH if exist "%APPDATA%\npm\dsh.cmd" set "DSH=%APPDATA%\npm\dsh.cmd"
if not defined DSH set "DSH=dsh"

echo [%date% %time%] auto-start begin (repo) >> "%LOG%"

rem ---- 1. update-confirm (asks first; skips when up to date or user says No) ----
if not exist "%PS1%" goto :startweb
powershell -NoProfile -ExecutionPolicy Bypass -STA -File "%PS1%"
echo [%date% %time%] update ps1 exit code: %errorlevel% >> "%LOG%"

:startweb
rem ---- 2. start the web UI; the browser opens the authenticated URL ----
call "%DSH%" web >> "%LOG%" 2>&1
