@echo off
rem Double-click installer - works regardless of the machine's PowerShell
rem execution policy (Bypass applies only to this invocation).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-HypervisorTray.ps1"
pause
