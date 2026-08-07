<#
.SYNOPSIS
    Installs (or removes) the Hypervisor Tray app for the current user. No admin needed.

    Install:   .\Install-HypervisorTray.ps1     (or double-click Install.bat)
    Uninstall: .\Install-HypervisorTray.ps1 -Uninstall

    Install copies HypervisorTray.ps1 to %LOCALAPPDATA%\HypervisorTray, adds a
    Startup-folder shortcut (via a wscript launcher where available, so no
    console flash at logon), and starts the tray now.

    -DirectLauncher skips the wscript hop: the shortcut runs PowerShell
    directly. Use it if logon ever shows a Windows Script Host error - the
    only cost is a brief console flash at logon.
#>
param([switch]$Uninstall, [switch]$DirectLauncher)

$ErrorActionPreference = 'Stop'

$dest       = Join-Path $env:LOCALAPPDATA 'HypervisorTray'
$destScript = Join-Path $dest 'HypervisorTray.ps1'
$roamDir    = Join-Path $env:APPDATA 'HypervisorTray'
$vbsPath    = Join-Path $roamDir 'HypervisorTray.vbs'
$pidFile    = Join-Path $dest 'tray.pid'
$shortcut   = Join-Path ([Environment]::GetFolderPath('Startup')) 'HypervisorTray.lnk'
$psExe      = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$psArgs     = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$destScript`""

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
                Write-Output "Stopped running tray (PID $trayPid). If a ghost icon lingers by the clock, hover over it to clear it."
            }
        }
    } catch { }
    Remove-Item -LiteralPath $pidFile -ErrorAction SilentlyContinue
}

function Test-WshAvailable {
    # VBScript is a removable Feature-on-Demand on Windows 11 24H2+, and
    # hardening baselines sometimes disable Windows Script Host outright.
    if (-not (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\vbscript.dll'))) { return $false }
    foreach ($root in 'HKLM:', 'HKCU:') {
        try {
            $v = (Get-ItemProperty -Path "$root\Software\Microsoft\Windows Script Host\Settings" -Name Enabled -ErrorAction Stop).Enabled
            if ($v -eq 0) { return $false }
        } catch { }
    }
    return $true
}

if ($Uninstall) {
    Stop-RunningTray
    if (Test-Path -LiteralPath $shortcut) { Remove-Item -LiteralPath $shortcut }
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
    if (Test-Path -LiteralPath $roamDir) { Remove-Item -LiteralPath $roamDir -Recurse -Force }
    Write-Output 'Hypervisor Tray uninstalled (startup shortcut, launcher, and app folder removed).'
    Write-Output 'Note: hypervisorlaunchtype itself is untouched - whatever mode is set stays set.'
    exit 0
}

# --- preflight warnings -----------------------------------------------------

$identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if ($identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Output "WARNING: running elevated. This installs PER-USER into the profile '$env:USERNAME' ($env:LOCALAPPDATA)."
    Write-Output '         If you elevated with a DIFFERENT admin account, close this and run it plainly (no Run as administrator).'
}

foreach ($scope in 'MachinePolicy', 'UserPolicy') {
    $pol = Get-ExecutionPolicy -Scope $scope
    if ($pol -in @('Restricted', 'AllSigned')) {
        Write-Output "WARNING: Group Policy enforces execution policy '$pol' at $scope scope."
        Write-Output '         That overrides this installer''s Bypass flag - the tray may be blocked at logon. Ask IT if it does not start.'
    }
}

# --- install ----------------------------------------------------------------

$source = Join-Path $PSScriptRoot 'HypervisorTray.ps1'
if (-not (Test-Path -LiteralPath $source)) {
    throw "HypervisorTray.ps1 not found next to this installer ($source)."
}

Stop-RunningTray
New-Item -ItemType Directory -Path $dest -Force | Out-Null
New-Item -ItemType Directory -Path $roamDir -Force | Out-Null
Copy-Item -LiteralPath $source -Destination $destScript -Force

# Gate on the app's self-test BEFORE creating any startup entry: on machines
# where PowerShell is restricted (AppLocker/WDAC Constrained Language Mode)
# the tray can never run, and installing a dead autostart would just produce
# a silent failure at every logon.
$test = Start-Process -FilePath $psExe -WindowStyle Hidden -Wait -PassThru `
    -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $destScript, '-SelfTest'
if ($test.ExitCode -ne 0) {
    Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $roamDir -Recurse -Force -ErrorAction SilentlyContinue
    throw ("Self-test failed (exit code $($test.ExitCode)) - not installing. This machine likely restricts PowerShell " +
        "(AppLocker/WDAC Constrained Language Mode or Group Policy). Check $dest\startup-error.log if it exists, or ask IT.")
}

# The launcher resolves %LOCALAPPDATA% at RUNTIME and checks the script
# exists before launching: no username is baked into the file (survives
# non-ASCII profile names) and a roaming profile carrying the Startup
# shortcut to a machine without the app silently no-ops instead of erroring
# at every logon. Written as UTF-16 (WSH-native) for the same reason.
$vbsLines = @(
    'Dim sh, fso, p'
    'Set sh = CreateObject("WScript.Shell")'
    'Set fso = CreateObject("Scripting.FileSystemObject")'
    'p = sh.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\HypervisorTray\HypervisorTray.ps1"'
    'If fso.FileExists(p) Then'
    '    sh.Run """" & sh.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & p & """", 0, False'
    'End If'
)
$useWsh = (-not $DirectLauncher) -and (Test-WshAvailable)
if ($useWsh) {
    Set-Content -LiteralPath $vbsPath -Value ($vbsLines -join "`r`n") -Encoding Unicode
} else {
    # No vbs in play - clean up a stale one from a previous wsh-mode install
    # so nothing references it.
    Remove-Item -LiteralPath $roamDir -Recurse -Force -ErrorAction SilentlyContinue
}

$ws = New-Object -ComObject WScript.Shell
$sc = $ws.CreateShortcut($shortcut)
if ($useWsh) {
    $sc.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $sc.Arguments = '"' + $vbsPath + '"'
} else {
    # No VBScript engine on this machine: launch PowerShell directly. Works
    # everywhere, at the cost of a brief console flash at logon.
    $sc.TargetPath = $psExe
    $sc.Arguments = $psArgs
}
$sc.WorkingDirectory = $dest
$sc.WindowStyle = 7
$sc.Description = 'Hypervisor mode tray toggle (Docker vs VirtualBox-fast)'
$sc.Save()

if ($useWsh) {
    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\wscript.exe') `
        -ArgumentList ('"' + $vbsPath + '"') -WorkingDirectory $dest
} else {
    Start-Process -FilePath $psExe -ArgumentList $psArgs -WindowStyle Hidden -WorkingDirectory $dest
}

# Confirm the tray actually came up (Stop-RunningTray deleted the old PID
# file, so a fresh one with a live process means the new instance started).
# Generous window: first-launch AV scanning can make WinForms startup slow.
$started = $false
foreach ($i in 1..120) {
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
if (-not $useWsh) {
    if ($DirectLauncher) {
        Write-Output 'Direct launcher selected: the tray starts via PowerShell directly (brief console flash at logon).'
    } else {
        Write-Output 'Note: VBScript/WSH is unavailable on this machine - the tray starts via PowerShell directly, which briefly flashes a console at logon.'
    }
}
if ($started) {
    if ((Get-CimInstance -ClassName Win32_ComputerSystem).HypervisorPresent) {
        $look = 'blue D (Docker mode)'
    } else {
        $look = 'orange V (VBox-fast mode)'
    }
    Write-Output "Tray started - look for the $look near the clock (it may be in the hidden-icons overflow)."
} else {
    Write-Output 'WARNING: the tray did not confirm startup within 30 seconds. Try running it manually:'
    Write-Output "  powershell -NoProfile -ExecutionPolicy Bypass -File `"$destScript`""
}
