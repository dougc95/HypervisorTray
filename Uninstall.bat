@echo off
if not exist "%~dp0Install-HypervisorTray.ps1" (
    echo Please EXTRACT the whole zip first, then run Uninstall.bat from the extracted folder.
    pause
    exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-HypervisorTray.ps1" -Uninstall
pause
