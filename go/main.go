//go:build windows

// turtle-hypervisor - a Windows tray toggle for hypervisorlaunchtype.
//
// Docker mode          = hypervisor ON  - Docker/WSL2 work, VirtualBox slower
// VirtualBox-fast mode = hypervisor OFF - VirtualBox native speed, no Docker
//
// The tray icon carries a fixed GUID so Windows recognises it as the same icon
// across restarts; that is what makes its taskbar visibility stick (a WinForms
// NotifyIcon is keyed to a window handle and looks new on every launch).
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

const (
	appName   = "turtle-hypervisor"
	className = "TurtleHypervisorTrayWnd"
	mutexName = "TurtleHypervisorSingleInstance"

	modeDocker = "docker"
	modeVBox   = "vbox"

	idToggle = 1001
	idReboot = 1002
	idExit   = 1003

	promoteTimerID = 1
)

// Stable identity for the tray icon. Do not change: Windows ties the user's
// show/hide choice to this GUID.
var iconGUID = guid{0x8f3a5c21, 0x7b4e, 0x4e6a, [8]byte{0x9c, 0x2d, 0x5a, 0x1b, 0x7e, 0x3f, 0x9d, 0x40}}

type state struct {
	NextBoot string `json:"nextBoot"`
	BootAt   int64  `json:"bootAt"`
}

var (
	hwnd        syscall.Handle
	currentIcon syscall.Handle
	currentMode string
	trayMsg     uint32
	taskbarMsg  uint32
	iconAdded   bool
	useGUID     = true
)

func appDir() string {
	return filepath.Join(os.Getenv("LOCALAPPDATA"), appName)
}

func statePath() string { return filepath.Join(appDir(), "state.json") }

// bootID identifies the current boot session; it is stable within a session
// and changes across reboots, which is all the pending-state logic needs.
func bootID() int64 {
	ticks, _, _ := procGetTickCount64.Call()
	boot := time.Now().Add(-time.Duration(uint64(ticks)) * time.Millisecond)
	return boot.Unix() / 10 * 10
}

// hypervisorPresent reports whether the Windows hypervisor is running, using
// the CPUID hypervisor-present bit (ECX bit 31 of leaf 1). Windows itself runs
// in the root partition when Hyper-V is on, so the bit is set there too.
func hypervisorPresent() bool {
	return cpuidECX1()&(1<<31) != 0
}

func detectMode() string {
	if hypervisorPresent() {
		return modeDocker
	}
	return modeVBox
}

func readNextBoot() string {
	cur := currentMode
	data, err := os.ReadFile(statePath())
	if err != nil {
		return cur
	}
	var s state
	if json.Unmarshal(data, &s) != nil {
		return cur
	}
	if s.BootAt != bootID() {
		return cur // written in an earlier boot session; already applied
	}
	if s.NextBoot == modeDocker || s.NextBoot == modeVBox {
		return s.NextBoot
	}
	return cur
}

func writeNextBoot(mode string) {
	os.MkdirAll(appDir(), 0o755)
	data, _ := json.Marshal(state{NextBoot: mode, BootAt: bootID()})
	os.WriteFile(statePath(), data, 0o644)
}

func modeLabel(m string) string {
	if m == modeDocker {
		return "Docker mode (hypervisor ON)"
	}
	return "VirtualBox-fast mode (hypervisor OFF)"
}

func modeShort(m string) string {
	if m == modeDocker {
		return "Docker mode"
	}
	return "VBox-fast mode"
}

func other(m string) string {
	if m == modeDocker {
		return modeVBox
	}
	return modeDocker
}

// ---------- tray icon ----------

func buildIcon(pending bool) syscall.Handle {
	if currentMode == modeDocker {
		return makeIcon("D", 0x00, 0x78, 0xD7, pending) // blue
	}
	return makeIcon("V", 0xE6, 0x7E, 0x22, pending) // orange
}

func newNID() notifyIconData {
	nid := notifyIconData{HWnd: hwnd, UID: 1}
	nid.CbSize = uint32(unsafe.Sizeof(nid))
	if useGUID {
		nid.GuidItem = iconGUID
	}
	return nid
}

func flags() uint32 {
	f := uint32(nifIcon | nifTip | nifMessage)
	if useGUID {
		f |= nifGUID
	}
	return f
}

func addOrUpdateIcon() {
	pending := readNextBoot() != currentMode

	icon := buildIcon(pending)
	if icon == 0 {
		return
	}

	tip := modeShort(currentMode)
	if pending {
		tip = fmt.Sprintf("Now: %s | Next boot: %s", modeShort(currentMode), modeShort(readNextBoot()))
	}

	nid := newNID()
	nid.UFlags = flags()
	nid.HIcon = icon
	nid.UCallbackMessage = trayMsg
	copyTip(&nid.SzTip, tip)

	op := uintptr(nimModify)
	if !iconAdded {
		op = nimAdd
	}
	ret, _, _ := procShellNotifyIconW.Call(op, uintptr(unsafe.Pointer(&nid)))
	if ret == 0 && !iconAdded && useGUID {
		// A GUID icon is bound to the executable path; if this binary has been
		// moved or a stale registration exists, fall back to handle identity.
		useGUID = false
		nid = newNID()
		nid.UFlags = flags()
		nid.HIcon = icon
		nid.UCallbackMessage = trayMsg
		copyTip(&nid.SzTip, tip)
		ret, _, _ = procShellNotifyIconW.Call(nimAdd, uintptr(unsafe.Pointer(&nid)))
	}
	if ret != 0 {
		iconAdded = true
	}

	if currentIcon != 0 {
		procDestroyIcon.Call(uintptr(currentIcon))
	}
	currentIcon = icon
}

func removeIcon() {
	if !iconAdded {
		return
	}
	nid := newNID()
	nid.UFlags = flags()
	procShellNotifyIconW.Call(nimDelete, uintptr(unsafe.Pointer(&nid)))
	iconAdded = false
}

// ---------- actions ----------

func toggleMode() {
	target := other(readNextBoot())
	value := "off"
	if target == modeDocker {
		value = "auto"
	}

	bcdedit := filepath.Join(os.Getenv("SystemRoot"), "System32", "bcdedit.exe")
	code, cancelled, err := runElevated(bcdedit, "/set hypervisorlaunchtype "+value)
	switch {
	case cancelled:
		messageBox("No changes made (the UAC prompt was declined).",
			appName+" - toggle cancelled", mbOK|mbIconWarning)
		return
	case err != nil:
		messageBox("Could not run bcdedit: "+err.Error(),
			appName+" - toggle failed", mbOK|mbIconError)
		return
	case code != 0:
		messageBox(fmt.Sprintf("bcdedit exited with code %d. The next-boot mode is unchanged.", code),
			appName+" - toggle failed", mbOK|mbIconError)
		return
	}

	writeNextBoot(target)
	addOrUpdateIcon()

	answer := messageBox(
		"Next boot: "+modeLabel(target)+"\n\nReboot now? (5-second countdown; abort with \"shutdown /a\")",
		appName, mbYesNo|mbIconQuestion)
	if answer == idYes {
		reboot()
	}
}

func reboot() {
	shutdown := filepath.Join(os.Getenv("SystemRoot"), "System32", "shutdown.exe")
	cmd := exec.Command(shutdown, "/r", "/t", "5", "/c", "Rebooting to switch hypervisor mode")
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	if err := cmd.Run(); err != nil {
		messageBox("Could not start the reboot: "+err.Error()+
			"\n\nIf a shutdown is already scheduled, run \"shutdown /a\" first.",
			appName+" - reboot failed", mbOK|mbIconError)
	}
}

func showMenu() {
	menu, _, _ := procCreatePopupMenu.Call()
	if menu == 0 {
		return
	}
	defer procDestroyMenu.Call(menu)

	next := readNextBoot()
	pending := next != currentMode

	add := func(flags uintptr, id uintptr, text string) {
		procAppendMenuW.Call(menu, flags, id, uintptr(unsafe.Pointer(utf16Ptr(text))))
	}

	add(mfString|mfGrayed, 0, "Current:   "+modeLabel(currentMode))
	nextText := "Next boot: " + modeLabel(next)
	if pending {
		nextText += "  - reboot pending"
	}
	add(mfString|mfGrayed, 0, nextText)
	add(mfSeparator, 0, "")
	add(mfString, idToggle, "Switch to "+modeShort(other(next))+" (next boot)...")
	add(mfString, idReboot, "Reboot now...")
	add(mfSeparator, 0, "")
	add(mfString, idExit, "Exit")

	var pt point
	procGetCursorPos.Call(uintptr(unsafe.Pointer(&pt)))
	procSetForegroundWindow.Call(uintptr(hwnd))
	cmd, _, _ := procTrackPopupMenu.Call(menu,
		tpmRightButton|tpmReturnCmd|tpmRightAlign|tpmBottomAlign,
		uintptr(pt.X), uintptr(pt.Y), 0, uintptr(hwnd), 0)
	procPostMessageW.Call(uintptr(hwnd), 0, 0, 0)

	switch cmd {
	case idToggle:
		toggleMode()
	case idReboot:
		if messageBox("Reboot now? (5-second countdown; abort with \"shutdown /a\")",
			appName, mbYesNo|mbIconQuestion) == idYes {
			reboot()
		}
	case idExit:
		procDestroyWindow.Call(uintptr(hwnd))
	}
}

// ---------- window ----------

func wndProc(h syscall.Handle, message uint32, wParam, lParam uintptr) uintptr {
	switch {
	case message == trayMsg:
		switch uint32(lParam) {
		case wmRButtonUp:
			showMenu()
		case wmLButtonDblClk:
			toggleMode()
		}
		return 0

	case taskbarMsg != 0 && message == taskbarMsg:
		// Explorer restarted - re-add the icon.
		iconAdded = false
		addOrUpdateIcon()
		return 0

	case message == wmTimer:
		if wParam == promoteTimerID {
			procKillTimer.Call(uintptr(h), promoteTimerID)
			promoteIcon()
		}
		return 0

	case message == wmCommand:
		return 0

	case message == wmClose:
		procDestroyWindow.Call(uintptr(h))
		return 0

	case message == wmDestroy:
		removeIcon()
		procPostQuitMessage.Call(0)
		return 0
	}
	ret, _, _ := procDefWindowProcW.Call(uintptr(h), uintptr(message), wParam, lParam)
	return ret
}

func createWindow() error {
	hInst, _, _ := procGetModuleHandleW.Call(0)

	wc := wndClassExW{
		LpfnWndProc:   syscall.NewCallback(wndProc),
		HInstance:     syscall.Handle(hInst),
		LpszClassName: utf16Ptr(className),
	}
	wc.CbSize = uint32(unsafe.Sizeof(wc))
	if ret, _, err := procRegisterClassExW.Call(uintptr(unsafe.Pointer(&wc))); ret == 0 {
		return fmt.Errorf("RegisterClassExW: %v", err)
	}

	h, _, err := procCreateWindowExW.Call(0,
		uintptr(unsafe.Pointer(utf16Ptr(className))),
		uintptr(unsafe.Pointer(utf16Ptr(appName))),
		0, 0, 0, 0, 0, 0, 0, hInst, 0)
	if h == 0 {
		return fmt.Errorf("CreateWindowExW: %v", err)
	}
	hwnd = syscall.Handle(h)
	return nil
}

func runTray() error {
	handle, _, err := procCreateMutexW.Call(0, 0, uintptr(unsafe.Pointer(utf16Ptr(mutexName))))
	if handle == 0 {
		return fmt.Errorf("CreateMutexW: %v", err)
	}
	if errno, ok := err.(syscall.Errno); ok && uintptr(errno) == errorAlreadyExists {
		return nil // already running
	}

	currentMode = detectMode()
	trayMsg = wmTrayCallback
	m, _, _ := procRegisterWindowMessage.Call(uintptr(unsafe.Pointer(utf16Ptr("TaskbarCreated"))))
	taskbarMsg = uint32(m)

	if err := createWindow(); err != nil {
		return err
	}
	addOrUpdateIcon()

	// Windows records the icon a moment after it first appears; promote it
	// once that entry exists so it sits on the taskbar, not in the overflow.
	procSetTimer.Call(uintptr(hwnd), promoteTimerID, 3000, 0)

	var m2 msg
	for {
		ret, _, _ := procGetMessageW.Call(uintptr(unsafe.Pointer(&m2)), 0, 0, 0)
		if int32(ret) <= 0 {
			break
		}
		procTranslateMessage.Call(uintptr(unsafe.Pointer(&m2)))
		procDispatchMessageW.Call(uintptr(unsafe.Pointer(&m2)))
	}
	return nil
}

// ---------- install ----------

func exePath() string {
	p, err := os.Executable()
	if err != nil {
		return ""
	}
	return p
}

func installedExe() string { return filepath.Join(appDir(), appName+".exe") }

func install() error {
	src := exePath()
	dst := installedExe()
	if err := os.MkdirAll(appDir(), 0o755); err != nil {
		return err
	}

	if !strings.EqualFold(src, dst) {
		stopRunning()
		time.Sleep(500 * time.Millisecond)
		data, err := os.ReadFile(src)
		if err != nil {
			return err
		}
		if err := os.WriteFile(dst, data, 0o755); err != nil {
			return fmt.Errorf("copy to %s: %w", dst, err)
		}
	}

	// Autostart: a Run entry pointing straight at the exe. No script host, no
	// interpreter, nothing for policy to block.
	run := exec.Command("reg", "add",
		`HKCU\Software\Microsoft\Windows\CurrentVersion\Run`,
		"/v", appName, "/t", "REG_SZ", "/d", `"`+dst+`"`, "/f")
	if out, err := run.CombinedOutput(); err != nil {
		return fmt.Errorf("reg add: %v: %s", err, out)
	}

	// Second, independent mechanism; the single-instance mutex discards
	// whichever one loses the race.
	task := exec.Command("schtasks", "/create", "/tn", appName,
		"/tr", `"`+dst+`"`, "/sc", "onlogon", "/delay", "0000:15", "/f")
	taskOut, taskErr := task.CombinedOutput()

	// Clean up anything the old PowerShell version installed.
	exec.Command("reg", "delete", `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`,
		"/v", "HypervisorTray", "/f").Run()
	exec.Command("schtasks", "/delete", "/tn", "HypervisorTray", "/f").Run()
	os.Remove(filepath.Join(os.Getenv("APPDATA"), "HypervisorTray", "HypervisorTray.vbs"))

	fmt.Println("Installed to", dst)
	fmt.Println("Autostart: HKCU Run entry")
	if taskErr == nil {
		fmt.Println("Autostart: logon scheduled task", appName)
	} else {
		fmt.Printf("Note: scheduled task not registered (%v: %s) - the Run entry still applies\n",
			taskErr, strings.TrimSpace(string(taskOut)))
	}

	cmd := exec.Command(dst)
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start tray: %w", err)
	}
	go cmd.Process.Release()

	fmt.Println("Tray started. If the icon is hidden, drag it out of the \"^\" overflow once,")
	fmt.Println("or turn it on under Settings > Personalization > Taskbar > Other system tray icons.")
	return nil
}

// stopRunning kills any running tray, but never this process: the installer
// shares the image name, so an unfiltered taskkill would kill itself.
func stopRunning() {
	hidden(exec.Command("taskkill", "/f", "/im", appName+".exe",
		"/fi", fmt.Sprintf("PID ne %d", os.Getpid()))).Run()
}

func uninstall() error {
	stopRunning()
	exec.Command("reg", "delete", `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`,
		"/v", appName, "/f").Run()
	exec.Command("schtasks", "/delete", "/tn", appName, "/f").Run()
	time.Sleep(500 * time.Millisecond)
	if err := os.RemoveAll(appDir()); err != nil {
		fmt.Println("Note: could not remove", appDir(), "-", err)
	}
	fmt.Println("Uninstalled. hypervisorlaunchtype itself is untouched.")
	return nil
}

func selfTest() error {
	fmt.Println("CurrentMode  :", detectMode())
	currentMode = detectMode()
	fmt.Println("NextBootMode :", readNextBoot())
	for _, pending := range []bool{true, false} {
		for _, m := range []string{modeDocker, modeVBox} {
			currentMode = m
			h := buildIcon(pending)
			if h == 0 {
				return fmt.Errorf("icon render failed for %s pending=%v", m, pending)
			}
			procDestroyIcon.Call(uintptr(h))
		}
	}
	fmt.Println("Icon render  : OK (4 variants)")
	fmt.Println("Boot ID      :", bootID())
	fmt.Println("SelfTest passed")
	return nil
}

func main() {
	action := ""
	if len(os.Args) > 1 {
		action = strings.ToLower(strings.TrimLeft(os.Args[1], "-/"))
	}

	var err error
	switch action {
	case "install":
		err = install()
	case "uninstall":
		err = uninstall()
	case "selftest":
		err = selfTest()
	case "":
		err = runTray()
	default:
		fmt.Printf("usage: %s [-install | -uninstall | -selftest]\n", appName)
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}
