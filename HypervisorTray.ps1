<#
.SYNOPSIS
    Tray icon showing the current hypervisor mode with a one-click toggle.

    Docker mode          = hypervisor ON  (hypervisorlaunchtype auto) - Docker/WSL2 work, VirtualBox slower (WHP)
    VirtualBox-fast mode = hypervisor OFF (hypervisorlaunchtype off)  - VirtualBox native speed, Docker/WSL2 blocked

    Runs unelevated; toggling triggers one UAC prompt for the bcdedit call.
    The change applies on the next reboot - a dialog offers to reboot immediately.

.NOTES
    Requires Windows PowerShell 5.1 (stock Windows 11). No modules, no binaries.
    Run with -SelfTest to exercise the non-UI logic headlessly.
#>
param([switch]$SelfTest)

$ErrorActionPreference = 'Stop'

# AppLocker/WDAC-managed machines run user-writable scripts in Constrained
# Language Mode, where Add-Type and WinForms are forbidden - fail loudly (and
# leave a log, since the logon launch is headless) instead of dying silently.
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    $reason = "Cannot start: PowerShell LanguageMode is '$($ExecutionContext.SessionState.LanguageMode)' (AppLocker/WDAC restriction) - FullLanguage is required."
    try {
        $logDir = Join-Path $env:LOCALAPPDATA 'HypervisorTray'
        if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        "[$(Get-Date)] $reason" | Set-Content -LiteralPath (Join-Path $logDir 'startup-error.log')
    } catch { }
    Write-Output "Hypervisor Tray: $reason"
    exit 1
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -Namespace Win32Native -Name IconUtil -MemberDefinition '[DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr handle); [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'

$script:StateDir  = Join-Path $env:LOCALAPPDATA 'HypervisorTray'
$script:StateFile = Join-Path $script:StateDir 'state.json'
$script:PidFile   = Join-Path $script:StateDir 'tray.pid'

# Both values are constants for the lifetime of a boot session, so they are
# queried once and cached - menu opens stay instant and a WMI hiccup cannot
# crash a UI event handler.
$script:CachedCurrentMode = $null
$script:CachedLastBoot    = $null
$script:ToggleInProgress  = $false

# ---------- mode detection ----------

function Get-CurrentMode {
    if ($null -eq $script:CachedCurrentMode) {
        if ((Get-CimInstance -ClassName Win32_ComputerSystem).HypervisorPresent) {
            $script:CachedCurrentMode = 'docker'
        } else {
            $script:CachedCurrentMode = 'vbox'
        }
    }
    return $script:CachedCurrentMode
}

function Get-LastBootTime {
    if ($null -eq $script:CachedLastBoot) {
        $script:CachedLastBoot = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime
    }
    return $script:CachedLastBoot
}

function Get-NextBootMode {
    # The state file records the last value this app wrote to the BCD, tagged
    # with the boot session it was written in (bootAt). A record from a
    # different boot session has already taken effect, so next boot = current
    # mode. Boot-session identity (equality) is immune to DST transitions and
    # clock adjustments, unlike timestamp ordering. External bcdedit changes
    # are invisible here (reading the BCD store needs admin, and this app
    # deliberately stays unelevated at rest).
    $current = Get-CurrentMode
    if (Test-Path -LiteralPath $script:StateFile) {
        try {
            $s = Get-Content -LiteralPath $script:StateFile -Raw | ConvertFrom-Json
            if ($s.PSObject.Properties['nextBoot'] -and $s.PSObject.Properties['bootAt'] -and
                ($s.nextBoot -in @('docker', 'vbox')) -and
                ($s.bootAt -eq (Get-LastBootTime).ToString('o'))) {
                return $s.nextBoot
            }
        } catch { }
    }
    return $current
}

function Save-NextBootMode([string]$mode) {
    if (-not (Test-Path -LiteralPath $script:StateDir)) {
        New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null
    }
    @{
        nextBoot = $mode
        bootAt   = (Get-LastBootTime).ToString('o')
        setAt    = (Get-Date).ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath $script:StateFile -Encoding UTF8
}

function Get-ModeLabel([string]$mode) {
    if ($mode -eq 'docker') { 'Docker mode (hypervisor ON)' } else { 'VirtualBox-fast mode (hypervisor OFF)' }
}

function Get-ModeShortLabel([string]$mode) {
    if ($mode -eq 'docker') { 'Docker mode' } else { 'VBox-fast mode' }
}

# ---------- icon rendering ----------

function New-ModeIcon([string]$mode, [bool]$pending) {
    # Render at the real tray icon size (scales with display DPI once the
    # process is DPI-aware) - a fixed 16x16 goes blurry at 125-200% scaling.
    $px = [System.Windows.Forms.SystemInformation]::SmallIconSize.Width
    if ($px -lt 16) { $px = 16 }
    $bmp = New-Object System.Drawing.Bitmap $px, $px
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        if ($mode -eq 'docker') {
            $bg = [System.Drawing.Color]::FromArgb(0, 120, 215)    # blue
            $letter = 'D'
        } else {
            $bg = [System.Drawing.Color]::FromArgb(230, 126, 34)   # orange
            $letter = 'V'
        }
        $brush = New-Object System.Drawing.SolidBrush $bg
        $g.FillEllipse($brush, 0, 0, ($px - 1), ($px - 1))
        $font = New-Object System.Drawing.Font('Segoe UI', ([single]($px * 0.47)), [System.Drawing.FontStyle]::Bold)
        $size = $g.MeasureString($letter, $font)
        $g.DrawString($letter, $font, [System.Drawing.Brushes]::White,
            ([single](($px - $size.Width) / 2)), ([single](($px - $size.Height) / 2)))
        if ($pending) {
            $dot = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::Gold)
            $dotSize = [int][Math]::Ceiling($px * 0.375)
            $dotOff = [int]($px * 0.625)
            $g.FillEllipse($dot, $dotOff, $dotOff, $dotSize, $dotSize)
            $dot.Dispose()
        }
        $brush.Dispose()
        $font.Dispose()
    } finally {
        $g.Dispose()
    }
    # Icon.FromHandle does not own the HICON from GetHicon - clone to an
    # owning Icon and destroy the original handle, otherwise every call leaks
    # a GDI object (per-process budget is 10,000; this app runs for weeks).
    $h = $bmp.GetHicon()
    $wrapper = [System.Drawing.Icon]::FromHandle($h)
    $icon = $wrapper.Clone()
    $wrapper.Dispose()
    [void][Win32Native.IconUtil]::DestroyIcon($h)
    $bmp.Dispose()
    return $icon
}

# ---------- dialogs ----------
# All dialogs are ownerless, so DefaultDesktopOnly is required to force them
# topmost (a tray app's MessageBox can otherwise open behind the foreground
# window). Balloon tips are NOT used for failures: Windows 11 silently
# swallows them under Do Not Disturb / notification settings.

function Show-Alert([string]$title, [string]$text, [string]$kind) {
    $icon = [System.Windows.Forms.MessageBoxIcon]::Information
    if ($kind -eq 'Warning') { $icon = [System.Windows.Forms.MessageBoxIcon]::Warning }
    if ($kind -eq 'Error')   { $icon = [System.Windows.Forms.MessageBoxIcon]::Error }
    [void][System.Windows.Forms.MessageBox]::Show($text, "Hypervisor Tray - $title",
        [System.Windows.Forms.MessageBoxButtons]::OK, $icon,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button1,
        [System.Windows.Forms.MessageBoxOptions]::DefaultDesktopOnly)
}

function Show-Confirm([string]$text) {
    $answer = [System.Windows.Forms.MessageBox]::Show($text, 'Hypervisor Tray',
        [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button1,
        [System.Windows.Forms.MessageBoxOptions]::DefaultDesktopOnly)
    return ($answer -eq [System.Windows.Forms.DialogResult]::Yes)
}

# ---------- actions ----------

function Invoke-RebootCommand([string]$comment) {
    $sp = Start-Process -FilePath 'shutdown.exe' -WindowStyle Hidden -Wait -PassThru `
        -ArgumentList '/r', '/t', '5', '/c', ('"' + $comment + '"')
    if ($sp.ExitCode -eq 1190) {
        Show-Alert 'Reboot already scheduled' 'A shutdown is already scheduled. Run "shutdown /a" to cancel it, then try again.' 'Warning'
    } elseif ($sp.ExitCode -ne 0) {
        Show-Alert 'Reboot failed' "shutdown.exe returned exit code $($sp.ExitCode)." 'Error'
    }
}

function Invoke-ModeToggle {
    # Re-entrancy guard: clicks queued while Start-Process -Wait blocks the UI
    # thread would otherwise replay into the confirmation dialog's message
    # pump and toggle the mode straight back with a second UAC prompt.
    if ($script:ToggleInProgress) { return }
    $script:ToggleInProgress = $true
    try {
        $next = Get-NextBootMode
        if ($next -eq 'docker') { $target = 'vbox' } else { $target = 'docker' }
        if ($target -eq 'docker') { $value = 'auto' } else { $value = 'off' }

        try {
            # If bcdedit fails to launch entirely, $LASTEXITCODE stays unset and a
            # bare "exit $LASTEXITCODE" would exit 0 - map that to failure.
            $p = Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle Hidden -Wait -PassThru `
                -ArgumentList '-NoProfile', '-NonInteractive', '-Command',
                    "bcdedit /set hypervisorlaunchtype $value; if (`$null -eq `$LASTEXITCODE) { exit 1 } else { exit `$LASTEXITCODE }"
        } catch {
            $w = $_.Exception.InnerException -as [System.ComponentModel.Win32Exception]
            if ($w -and $w.NativeErrorCode -eq 1223) {
                Show-Alert 'Toggle cancelled' 'No changes made (the UAC prompt was declined or timed out).' 'Warning'
            } else {
                Show-Alert 'Toggle failed' ('Could not launch the elevated helper: ' + $_.Exception.Message) 'Error'
            }
            return
        }
        if (($null -eq $p) -or ($null -eq $p.ExitCode) -or ($p.ExitCode -ne 0)) {
            $code = 'unknown'
            if ($p -and ($null -ne $p.ExitCode)) { $code = $p.ExitCode }
            Show-Alert 'Toggle failed' "bcdedit did not confirm success (exit code $code). The next-boot mode is unchanged." 'Error'
            return
        }

        Save-NextBootMode $target
        Update-Ui
        $msg = "Next boot: {0}.`n`nReboot now? (5-second countdown; abort with 'shutdown /a')" -f (Get-ModeLabel $target)
        if (Show-Confirm $msg) {
            Invoke-RebootCommand 'Rebooting to switch hypervisor mode'
        }
    } finally {
        $script:ToggleInProgress = $false
    }
}

function Invoke-RebootNow {
    if (Show-Confirm "Reboot now? (5-second countdown; abort with 'shutdown /a')") {
        Invoke-RebootCommand 'Rebooting (Hypervisor Tray)'
    }
}

# ---------- UI ----------

function Update-Ui {
    $current = Get-CurrentMode
    $next = Get-NextBootMode
    $pending = ($next -ne $current)

    $oldIcon = $script:Notify.Icon
    $script:Notify.Icon = New-ModeIcon $current $pending
    if ($oldIcon) { $oldIcon.Dispose() }

    if ($pending) {
        $tip = 'Now: {0} | Next boot: {1}' -f (Get-ModeShortLabel $current), (Get-ModeShortLabel $next)
    } else {
        $tip = Get-ModeShortLabel $current
    }
    if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }   # NotifyIcon.Text hard limit
    $script:Notify.Text = $tip

    $script:MiCurrent.Text = 'Current:   ' + (Get-ModeLabel $current)
    $suffix = ''
    if ($pending) { $suffix = '  - reboot pending' }
    $script:MiNext.Text = 'Next boot: ' + (Get-ModeLabel $next) + $suffix

    if ($next -eq 'docker') { $other = 'vbox' } else { $other = 'docker' }
    $script:MiToggle.Text = 'Switch to ' + (Get-ModeShortLabel $other) + ' (next boot)...'
}

# ---------- self test ----------

if ($SelfTest) {
    Write-Output ('CurrentMode  : ' + (Get-CurrentMode))
    Write-Output ('NextBootMode : ' + (Get-NextBootMode))
    foreach ($m in 'docker', 'vbox') {
        foreach ($p in $true, $false) {
            $i = New-ModeIcon $m $p
            if ($null -eq $i) { throw "icon render failed for $m pending=$p" }
            $i.Dispose()
        }
    }
    Write-Output 'Icon render  : OK (4 variants)'
    # Round-trip the state file against a temp dir so the real state is
    # untouched. Write the OPPOSITE of the current mode: the fallback path
    # returns the current mode, so an identical expected value could mask a
    # broken pending-detection condition.
    $realDir = $script:StateDir; $realFile = $script:StateFile
    $script:StateDir = Join-Path $env:TEMP ('HypervisorTraySelfTest_' + $PID)
    $script:StateFile = Join-Path $script:StateDir 'state.json'
    try {
        if ((Get-CurrentMode) -eq 'docker') { $expected = 'vbox' } else { $expected = 'docker' }
        Save-NextBootMode $expected
        $roundTrip = Get-NextBootMode
        if ($roundTrip -ne $expected) { throw "state round-trip failed: wrote $expected, read back $roundTrip" }
        Write-Output ("State file   : wrote $expected, read back $roundTrip - OK")
    } finally {
        if (Test-Path -LiteralPath $script:StateDir) { Remove-Item -LiteralPath $script:StateDir -Recurse -Force }
        $script:StateDir = $realDir; $script:StateFile = $realFile
    }
    Write-Output 'SelfTest passed'
    exit 0
}

# ---------- main ----------

# Single instance. The timeout absorbs a predecessor still tearing down after
# a kill (installer replace path); AbandonedMutexException means the previous
# owner died holding the mutex - the excepting thread now owns it.
$mutex = New-Object System.Threading.Mutex($false, 'HypervisorTray_SingleInstance')
$owned = $false
try {
    $owned = $mutex.WaitOne(2000, $false)
} catch [System.Threading.AbandonedMutexException] {
    $owned = $true
}
if (-not $owned) {
    Write-Output 'Hypervisor Tray is already running.'
    exit 0
}

try {
    if (-not (Test-Path -LiteralPath $script:StateDir)) {
        New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null
    }
    # Move CWD out of wherever we were launched from (e.g. a freshly unzipped
    # folder the user will want to delete) - a process's CWD locks the folder.
    Set-Location -LiteralPath $script:StateDir
    $PID | Set-Content -LiteralPath $script:PidFile -Encoding ASCII

    [void][Win32Native.IconUtil]::SetProcessDPIAware()
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $script:Notify = New-Object System.Windows.Forms.NotifyIcon
    $menu = New-Object System.Windows.Forms.ContextMenuStrip

    $script:MiCurrent = New-Object System.Windows.Forms.ToolStripMenuItem
    $script:MiCurrent.Enabled = $false
    $script:MiNext = New-Object System.Windows.Forms.ToolStripMenuItem
    $script:MiNext.Enabled = $false
    $script:MiToggle = New-Object System.Windows.Forms.ToolStripMenuItem
    $miReboot = New-Object System.Windows.Forms.ToolStripMenuItem
    $miReboot.Text = 'Reboot now...'
    $miExit = New-Object System.Windows.Forms.ToolStripMenuItem
    $miExit.Text = 'Exit'

    [void]$menu.Items.Add($script:MiCurrent)
    [void]$menu.Items.Add($script:MiNext)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void]$menu.Items.Add($script:MiToggle)
    [void]$menu.Items.Add($miReboot)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void]$menu.Items.Add($miExit)

    $script:MiToggle.add_Click({ Invoke-ModeToggle })
    $miReboot.add_Click({ Invoke-RebootNow })
    $miExit.add_Click({
        $script:Notify.Visible = $false
        [System.Windows.Forms.Application]::Exit()
    })
    $menu.add_Opening({ try { Update-Ui } catch { } })
    # MouseDoubleClick fires for every button; only a LEFT double-click should
    # toggle (a fast double right-click is a natural menu gesture and must not
    # spring a UAC prompt).
    $script:Notify.add_MouseDoubleClick({
        if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Invoke-ModeToggle }
    })

    $script:Notify.ContextMenuStrip = $menu
    Update-Ui
    $script:Notify.Visible = $true

    $ctx = New-Object System.Windows.Forms.ApplicationContext
    [System.Windows.Forms.Application]::Run($ctx)
} finally {
    if ($script:Notify) { $script:Notify.Visible = $false; $script:Notify.Dispose() }
    Remove-Item -LiteralPath $script:PidFile -ErrorAction SilentlyContinue
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
