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

```powershell
.\Install-HypervisorTray.ps1
```

Copies the script to `%LOCALAPPDATA%\HypervisorTray`, adds a Startup-folder shortcut (launched via `wscript` so no console flashes at logon), and starts the tray. No admin needed.

## Uninstall

```powershell
.\Install-HypervisorTray.ps1 -Uninstall
```

Removes the shortcut and app folder. The current `hypervisorlaunchtype` value is left as-is.

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
- [docs/2026-08-07-design.md](docs/2026-08-07-design.md) — design notes
