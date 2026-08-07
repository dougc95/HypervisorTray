@echo off
rem Double-click installer. Bypass applies only to this invocation; note that
rem Group Policy-enforced execution policy still overrides it.
if not exist "%~dp0Install-HypervisorTray.ps1" (
    echo Please EXTRACT the whole zip first, then run Install.bat from the extracted folder.
    pause
    exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-HypervisorTray.ps1"
pause
