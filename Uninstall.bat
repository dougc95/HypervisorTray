@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-HypervisorTray.ps1" -Uninstall
pause
