@echo off
chcp 65001 >nul
title Codex Computer Use Repair
echo Please fully quit Codex from the system tray before continuing.
echo This repair creates backups and does not modify the signed WindowsApps package.
echo.
where pwsh.exe >nul 2>&1
if errorlevel 1 (
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0repair-codex-computer-use.ps1"
) else (
  pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0repair-codex-computer-use.ps1"
)
set "repair_exit_code=%ERRORLEVEL%"
echo.
if not "%repair_exit_code%"=="0" (
  echo Repair did not complete. Read the error above; existing backups were not deleted.
) else (
  echo Repair completed. Reopen Codex and start a new task to test Computer Use.
)
echo.
pause
exit /b %repair_exit_code%
