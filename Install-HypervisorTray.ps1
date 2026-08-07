<#
.SYNOPSIS
    Installs (or removes) the Hypervisor Tray app for the current user. No admin needed.

    Install:   .\Install-HypervisorTray.ps1
    Uninstall: .\Install-HypervisorTray.ps1 -Uninstall

    Install copies HypervisorTray.ps1 to %LOCALAPPDATA%\HypervisorTray, adds a
    Startup-folder shortcut (via a wscript launcher, so no console flash at
    logon), and starts the tray now.
#>
param([switch]$Uninstall)

$ErrorActionPreference = 'Stop'

$dest       = Join-Path $env:LOCALAPPDATA 'HypervisorTray'
$destScript = Join-Path $dest 'HypervisorTray.ps1'
$vbsPath    = Join-Path $dest 'HypervisorTray.vbs'
$pidFile    = Join-Path $dest 'tray.pid'
$shortcut   = Join-Path ([Environment]::GetFolderPath('Startup')) 'HypervisorTray.lnk'
$psExe      = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Stop-RunningTray {
    # Only kill a process that is verifiably the tray: the PID file can be
    # stale (the tray's cleanup never runs on logoff/kill) and Windows reuses
    # PIDs aggressively, so PID + process name alone could kill an innocent
    # PowerShell console.
    if (-not (Test-Path -LiteralPath $pidFile)) { return }
    try {
        $trayPid = [int](Get-Content -LiteralPath $pidFile -Raw).Trim()
        if ($trayPid -ne $PID) {
            $wp = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$trayPid" -ErrorAction Stop
            if ($wp -and $wp.CommandLine -match 'HypervisorTray\.ps1') {
                $proc = Get-Process -Id $trayPid -ErrorAction Stop
                Stop-Process -Id $trayPid -Force
                [void]$proc.WaitForExit(5000)   # let it fully release the mutex before we relaunch
                Write-Output "Stopped running tray (PID $trayPid)."
            }
        }
    } catch { }
    Remove-Item -LiteralPath $pidFile -ErrorAction SilentlyContinue
}

if ($Uninstall) {
    Stop-RunningTray
    if (Test-Path -LiteralPath $shortcut) { Remove-Item -LiteralPath $shortcut }
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
    Write-Output 'Hypervisor Tray uninstalled (startup shortcut and app folder removed).'
    Write-Output 'Note: hypervisorlaunchtype itself is untouched - whatever mode is set stays set.'
    exit 0
}

$source = Join-Path $PSScriptRoot 'HypervisorTray.ps1'
if (-not (Test-Path -LiteralPath $source)) {
    throw "HypervisorTray.ps1 not found next to this installer ($source)."
}

Stop-RunningTray
New-Item -ItemType Directory -Path $dest -Force | Out-Null
Copy-Item -LiteralPath $source -Destination $destScript -Force

# wscript launcher: powershell.exe shows its console before -WindowStyle Hidden
# is parsed, so launching it directly flashes a window at every logon.
# wscript.exe has no console, so nothing ever appears.
$vbs = 'CreateObject("WScript.Shell").Run """' + $psExe + '"" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""' + $destScript + '""", 0, False'
Set-Content -LiteralPath $vbsPath -Value $vbs -Encoding ASCII

$ws = New-Object -ComObject WScript.Shell
$sc = $ws.CreateShortcut($shortcut)
$sc.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
$sc.Arguments = '"' + $vbsPath + '"'
$sc.WorkingDirectory = $dest
$sc.WindowStyle = 7
$sc.Description = 'Hypervisor mode tray toggle (Docker vs VirtualBox-fast)'
$sc.Save()

Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\wscript.exe') -ArgumentList ('"' + $vbsPath + '"')

# Confirm the tray actually came up (Stop-RunningTray deleted the old PID
# file, so a fresh one with a live process means the new instance started).
$started = $false
foreach ($i in 1..40) {
    Start-Sleep -Milliseconds 250
    if (Test-Path -LiteralPath $pidFile) {
        try {
            $newPid = [int](Get-Content -LiteralPath $pidFile -Raw).Trim()
            if (Get-Process -Id $newPid -ErrorAction SilentlyContinue) { $started = $true; break }
        } catch { }
    }
}

Write-Output "Installed to $dest"
Write-Output "Startup shortcut: $shortcut"
if ($started) {
    if ((Get-CimInstance -ClassName Win32_ComputerSystem).HypervisorPresent) {
        $look = 'blue D (Docker mode)'
    } else {
        $look = 'orange V (VBox-fast mode)'
    }
    Write-Output "Tray started - look for the $look near the clock (it may be in the hidden-icons overflow)."
} else {
    Write-Output 'WARNING: the tray did not confirm startup within 10 seconds. Try running it manually:'
    Write-Output "  powershell -NoProfile -ExecutionPolicy Bypass -File `"$destScript`""
}
