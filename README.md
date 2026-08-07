# Hypervisor Tray

A tiny Windows 11 tray app that shows which hypervisor mode the machine booted in and toggles it with one click. No dependencies — a single PowerShell 5.1 script using WinForms.

## The problem it solves

On Windows, the hypervisor is a per-boot, all-or-nothing switch:

| Mode | `hypervisorlaunchtype` | Docker Desktop / WSL2 | VirtualBox |
|---|---|---|---|
| **Docker mode** (blue **D**) | `auto` | ✅ works | 🐢 slower (WHP engine) |
| **VBox-fast mode** (orange **V**) | `off` | ❌ cannot start | ⚡ native VT-x speed |

You can't have both at once, but you *can* make switching painless. This tray shows the current mode at a glance and flips the setting for the next boot.

## Usage

- **Tray icon** = current boot's mode. A gold dot means a mode change is pending a reboot.
- **Right-click** → status lines, **Switch to … mode (next boot)…**, **Reboot now…**, Exit.
- **Left double-click** = toggle.
- Toggling triggers **one UAC prompt** (the app itself stays unelevated), then offers to reboot now (5-second countdown, abortable with `shutdown /a`) or later.

## Install

Double-click **`Install.bat`** (or run `powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-HypervisorTray.ps1`).

Copies the script to `%LOCALAPPDATA%\HypervisorTray`, adds a Startup-folder shortcut (launched via `wscript` so no console flashes at logon), and starts the tray. No admin needed — installation is per-user.

## Uninstall

Double-click **`Uninstall.bat`** (or run `powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-HypervisorTray.ps1 -Uninstall`).

Removes the shortcut and app folder. The current `hypervisorlaunchtype` value is left as-is.

## Sharing / running on another machine

The whole folder is self-contained. Easiest: send people the repo's **Code → Download ZIP** link on GitHub (that zip has no git history in it — zipping the folder yourself would include the hidden `.git` directory unless you use `git archive`). On the target machine:

1. **Extract the zip first**, then double-click `Install.bat`. The `.bat` wrappers pass `-ExecutionPolicy Bypass`, which clears the *default* script-execution block on stock Windows.
2. If Windows flags the downloaded files (Mark of the Web), right-click the `.zip` **before extracting** → Properties → **Unblock**, or run this inside the extracted folder:

   ```powershell
   Get-ChildItem -Recurse | Unblock-File
   ```

**Corporate machines:** if your organization enforces PowerShell policy via Group Policy or AppLocker/WDAC, that *overrides* the Bypass flag — the installer detects this, warns, and refuses to install a dead autostart entry. Ask IT in that case. On machines where VBScript/WSH has been removed, the installer automatically falls back to a direct PowerShell autostart (works fine, briefly flashes a console at logon).

**Requirements:** Windows 10 or 11 with Windows PowerShell 5.1 (built in — nothing to install). Toggling requires the user to be able to approve a UAC admin prompt.

## Manual run / self-test

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\HypervisorTray.ps1            # run in foreground
powershell -NoProfile -ExecutionPolicy Bypass -File .\HypervisorTray.ps1 -SelfTest  # headless logic test
```

## How it works

- **Current mode**: `Win32_ComputerSystem.HypervisorPresent` via CIM — needs no admin and cannot change mid-boot, so the icon is always truthful.
- **Toggle**: `bcdedit /set hypervisorlaunchtype auto|off` run elevated via `Start-Process -Verb RunAs` (the one UAC prompt).
- **Next-boot state**: reading the BCD store needs admin, so the app records what it last wrote in `%LOCALAPPDATA%\HypervisorTray\state.json`, tagged with the boot session it was written in. Records from an earlier boot session are treated as consumed. Session identity (not timestamps) makes this immune to DST transitions and clock adjustments.

## Limitations

- Changes made with `bcdedit` outside this app aren't detected (by design — the app stays unelevated at rest).
- Windows can silently re-enable the hypervisor even with `hypervisorlaunchtype off` if **Memory Integrity** (Core Isolation) or Smart App Control turns on — check after feature updates. The icon will tell you: it reports what actually booted.
- A reboot is required to switch modes. That's Windows, not the app.

## Files

- [HypervisorTray.ps1](HypervisorTray.ps1) — the tray app
- [Install-HypervisorTray.ps1](Install-HypervisorTray.ps1) — install / uninstall
- [Install.bat](Install.bat) / [Uninstall.bat](Uninstall.bat) — double-click wrappers (handle execution policy)
- [docs/2026-08-07-design.md](docs/2026-08-07-design.md) — design notes
- [LICENSE](LICENSE) — MIT
