@echo off
rem ===========================================================================
rem  DeepSeek Harness Web UI - one-click restart helper
rem  Usage   : double-click this file (or run: restart-dsh-web.cmd)
rem  What    : stops the dsh web currently listening on %PORT%, then relaunches
rem            it through the VBS auto-start script (the same path the logon
rem            autostart uses: update check -> start web --no-open).
rem  Port    : change PORT below if your web UI is configured on another port.
rem ===========================================================================
setlocal enabledelayedexpansion

set "PORT=3080"
set "VBS=%USERPROFILE%\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\dsh-web-autostart.vbs"
set "URL=http://127.0.0.1:%PORT%"

echo ============================================================
echo  DeepSeek Harness Web UI - restart
echo  Port : %PORT%
echo  VBS  : %VBS%
echo ============================================================

rem ---- 1. stop whatever is LISTENING on the port ----
set "FOUND="
for /f "tokens=5" %%p in ('netstat -ano ^| findstr /C:":%PORT% " ^| findstr /C:"LISTENING"') do (
  set "FOUND=1"
  echo Stopping dsh web PID %%p
  taskkill /PID %%p /T /F >nul 2>&1
)
if not defined FOUND echo No dsh web found on port %PORT% - nothing to stop.

rem ---- 2. let the port release ----
ping -n 4 127.0.0.1 >nul

rem ---- 3. relaunch via the VBS auto-start ----
if not exist "%VBS%" (
  echo [ERROR] VBS not found: %VBS%
  exit /b 1
)
echo Launching via VBS: %VBS%
wscript.exe "%VBS%"

rem ---- 4. wait up to ~28s for the web UI to come back ----
echo Waiting for the web UI to come back ...
set "UP="
for /l %%i in (1,1,7) do (
  ping -n 4 127.0.0.1 >nul
  for /f "tokens=5" %%p in ('netstat -ano ^| findstr /C:":%PORT% " ^| findstr /C:"LISTENING"') do set "UP=1"
  if defined UP goto :up
)

:up
echo.
if defined UP (
  echo [OK] dsh web is running: %URL%
) else (
  echo [WARN] not up yet. The auto-start updates dsh first and can take longer
  echo        on the first run. Wait a bit, then check %URL% or see
  echo        %USERPROFILE%\.dsh\autostart-update.log
)
echo.
pause
endlocal
