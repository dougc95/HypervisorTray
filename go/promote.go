//go:build windows

package main

import (
	"os/exec"
	"strings"
	"syscall"
)

func cpuidECX1() uint32

func hidden(cmd *exec.Cmd) *exec.Cmd {
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	return cmd
}

// promoteIcon asks Windows to show this icon on the taskbar rather than in the
// hidden overflow flyout. Windows creates the entry shortly after the icon
// first appears, so this runs on a short delay after startup.
func promoteIcon() {
	const base = `HKCU\Control Panel\NotifyIconSettings`
	out, err := hidden(exec.Command("reg", "query", base)).Output()
	if err != nil {
		return
	}
	for _, line := range strings.Split(string(out), "\n") {
		sub := strings.TrimSpace(line)
		if !strings.HasPrefix(sub, base+`\`) {
			continue
		}
		vals, err := hidden(exec.Command("reg", "query", sub, "/v", "ExecutablePath")).Output()
		if err != nil || !strings.Contains(strings.ToLower(string(vals)), appName+".exe") {
			continue
		}
		hidden(exec.Command("reg", "add", sub, "/v", "IsPromoted",
			"/t", "REG_DWORD", "/d", "1", "/f")).Run()
	}
}
