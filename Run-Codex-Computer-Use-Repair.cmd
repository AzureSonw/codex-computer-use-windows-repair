@echo off
chcp 65001 >nul
title Codex Computer Use Repair
echo Checking the installed Codex version and Computer Use files first.
echo Healthy installations will be left as they are. Repair runs only when needed.
echo If repair is needed, keep this window open and fully quit ChatGPT/Codex.
echo This run can wait up to 120 seconds for the displayed blocking processes.
echo If Chrome integration needs repair, the trusted Codex app will then open once.
echo.
where pwsh.exe >nul 2>&1
if errorlevel 1 (
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0check-codex-computer-use.ps1" -WaitSeconds 120 -InitializeChrome
) else (
  pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0check-codex-computer-use.ps1" -WaitSeconds 120 -InitializeChrome
)
set "repair_exit_code=%ERRORLEVEL%"
echo.
if not "%repair_exit_code%"=="0" (
  echo Check or repair needs attention. Read the result above; backups were not deleted.
) else (
  echo Check completed. Any required repair completed successfully.
)
echo.
pause
exit /b %repair_exit_code%
