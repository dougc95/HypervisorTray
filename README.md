# turtle-hypervisor

*For when the green turtle moves in.*

A tiny Windows tray app that shows which hypervisor mode the machine booted in and toggles it with one click. A single Go binary — no runtime, no dependencies, no scripts.

(The name: when VirtualBox runs on top of Hyper-V it shows a green turtle icon, meaning your VMs are on the slow path. This tray decides who gets the hypervisor — Docker or VirtualBox — so the turtle only shows up when you've chosen it.)

## The problem it solves

On Windows, the hypervisor is a per-boot, all-or-nothing switch:

| Mode | `hypervisorlaunchtype` | Docker Desktop / WSL2 | VirtualBox |
|---|---|---|---|
| **Docker mode** (blue **D**) | `auto` | ✅ works | 🐢 slower (WHP engine) |
| **VBox-fast mode** (orange **V**) | `off` | ❌ cannot start | ⚡ native VT-x speed |

You can't have both at once, but you *can* make switching painless. This tray shows the current mode at a glance and flips the setting for the next boot.

## Usage

- **Tray icon** = the mode this boot is running in. A gold dot means a mode change is pending a reboot.
- **Right-click** → status lines, **Switch to … (next boot)…**, **Reboot now…**, Exit.
- **Left double-click** = toggle.
- Toggling raises **one UAC prompt** (the app itself runs unelevated), then offers to reboot now — 5-second countdown, abortable with `shutdown /a` — or later.

## Install

```
turtle-hypervisor.exe -install
```

Copies itself to `%LOCALAPPDATA%\turtle-hypervisor`, registers a per-user logon autostart, and starts the tray. No admin required.

Uninstall with `turtle-hypervisor.exe -uninstall` (leaves `hypervisorlaunchtype` exactly as it is). `-selftest` runs the non-UI checks: mode detection, state round-trip, icon rendering.

## Build

```
cd go && go build -ldflags="-H=windowsgui -s -w" -o ../turtle-hypervisor.exe .
```

Requires Go 1.26+ and amd64 Windows. Pure standard library — `syscall` bindings to user32/shell32/gdi32, no modules to fetch.

## How it works

- **Current mode**: the CPUID leaf-1 hypervisor-present bit (ECX bit 31). Needs no admin and cannot change mid-boot, so the icon is always truthful.
- **Toggle**: `bcdedit /set hypervisorlaunchtype auto|off`, run elevated through `ShellExecuteEx` with the `runas` verb — the single UAC prompt.
- **Next-boot state**: reading the BCD needs admin, so the app records what it last wrote in `state.json`, tagged with the boot session it was written in. Entries from an earlier session are treated as already applied, which makes the pending marker immune to clock changes and DST.
- **The icon carries a fixed GUID.** This matters: an icon identified only by its window handle looks brand-new to Windows on every launch, so it gets filed into the hidden overflow every time and no "show this icon" setting can stick. With a stable GUID, your choice persists.

## Troubleshooting

**Icon is in the hidden overflow** — drag it out onto the taskbar once, or turn it on under **Settings → Personalization → Taskbar → Other system tray icons → turtle-hypervisor.exe**. With the fixed GUID this only needs doing once.

**Tray doesn't start at logon** — check the autostart entries:

```
schtasks /query /tn turtle-hypervisor
reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v turtle-hypervisor
```

On some machines Explorer never processes `Run` entries; the logon scheduled task covers that case. Run `turtle-hypervisor.exe -install` again to recreate both.

**Mode looks wrong after a Windows update** — feature updates can silently re-enable Memory Integrity (Core Isolation), which turns the hypervisor back on. The icon reports what actually booted, so trust it over what you last set.

## Limitations

- Changes made to `hypervisorlaunchtype` outside this app aren't detected for the *pending* indicator (reading the BCD store requires admin; the app deliberately stays unelevated at rest). The current-mode icon is always correct.
- Switching modes requires a reboot. That's Windows, not the app.
- amd64 Windows only.

## Files

- [go/](go) — the source (`main.go` app logic, `win32.go` API bindings, `icon.go` icon drawing, `promote.go` taskbar promotion, `cpuid_amd64.s` hypervisor detection)
- [LICENSE](LICENSE) — MIT
