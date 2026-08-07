//go:build windows

package main

import (
	"syscall"
	"unsafe"
)

var (
	user32   = syscall.NewLazyDLL("user32.dll")
	shell32  = syscall.NewLazyDLL("shell32.dll")
	gdi32    = syscall.NewLazyDLL("gdi32.dll")
	kernel32 = syscall.NewLazyDLL("kernel32.dll")

	procRegisterClassExW      = user32.NewProc("RegisterClassExW")
	procCreateWindowExW       = user32.NewProc("CreateWindowExW")
	procDefWindowProcW        = user32.NewProc("DefWindowProcW")
	procDestroyWindow         = user32.NewProc("DestroyWindow")
	procGetMessageW           = user32.NewProc("GetMessageW")
	procTranslateMessage      = user32.NewProc("TranslateMessage")
	procDispatchMessageW      = user32.NewProc("DispatchMessageW")
	procPostQuitMessage       = user32.NewProc("PostQuitMessage")
	procRegisterWindowMessage = user32.NewProc("RegisterWindowMessageW")
	procCreatePopupMenu       = user32.NewProc("CreatePopupMenu")
	procDestroyMenu           = user32.NewProc("DestroyMenu")
	procAppendMenuW           = user32.NewProc("AppendMenuW")
	procTrackPopupMenu        = user32.NewProc("TrackPopupMenu")
	procSetForegroundWindow   = user32.NewProc("SetForegroundWindow")
	procPostMessageW          = user32.NewProc("PostMessageW")
	procGetCursorPos          = user32.NewProc("GetCursorPos")
	procMessageBoxW           = user32.NewProc("MessageBoxW")
	procGetSystemMetrics      = user32.NewProc("GetSystemMetrics")
	procDrawTextW             = user32.NewProc("DrawTextW")
	procFillRect              = user32.NewProc("FillRect")
	procSetTimer              = user32.NewProc("SetTimer")
	procKillTimer             = user32.NewProc("KillTimer")

	procShellNotifyIconW = shell32.NewProc("Shell_NotifyIconW")
	procShellExecuteExW  = shell32.NewProc("ShellExecuteExW")

	procCreateCompatibleDC = gdi32.NewProc("CreateCompatibleDC")
	procDeleteDC           = gdi32.NewProc("DeleteDC")
	procCreateDIBSection   = gdi32.NewProc("CreateDIBSection")
	procCreateBitmap       = gdi32.NewProc("CreateBitmap")
	procSelectObject       = gdi32.NewProc("SelectObject")
	procDeleteObject       = gdi32.NewProc("DeleteObject")
	procCreateFontW        = gdi32.NewProc("CreateFontW")
	procSetTextColor       = gdi32.NewProc("SetTextColor")
	procSetBkMode          = gdi32.NewProc("SetBkMode")
	procCreateIconIndirect = user32.NewProc("CreateIconIndirect")
	procDestroyIcon        = user32.NewProc("DestroyIcon")

	procGetTickCount64      = kernel32.NewProc("GetTickCount64")
	procCreateMutexW        = kernel32.NewProc("CreateMutexW")
	procGetModuleHandleW    = kernel32.NewProc("GetModuleHandleW")
	procWaitForSingleObject = kernel32.NewProc("WaitForSingleObject")
	procGetExitCodeProcess  = kernel32.NewProc("GetExitCodeProcess")
	procCloseHandle         = kernel32.NewProc("CloseHandle")
)

const (
	wmDestroy       = 0x0002
	wmClose         = 0x0010
	wmCommand       = 0x0111
	wmTimer         = 0x0113
	wmRButtonUp     = 0x0205
	wmLButtonDblClk = 0x0203
	wmApp           = 0x8000

	wmTrayCallback = wmApp + 1

	nimAdd        = 0x00000000
	nimModify     = 0x00000001
	nimDelete     = 0x00000002
	nifMessage    = 0x00000001
	nifIcon       = 0x00000002
	nifTip        = 0x00000004
	nifGUID       = 0x00000020
	nifShowTip    = 0x00000080
	mfString      = 0x00000000
	mfSeparator   = 0x00000800
	mfGrayed      = 0x00000001
	tpmRightAlign = 0x0008
	tpmBottomAlign = 0x0020
	tpmRightButton = 0x0002
	tpmReturnCmd   = 0x0100

	mbYesNo       = 0x00000004
	mbOK          = 0x00000000
	mbIconQuestion = 0x00000020
	mbIconError    = 0x00000010
	mbIconWarning  = 0x00000030
	mbSetForeground = 0x00010000
	mbTopMost      = 0x00040000
	idYes          = 6

	smCXSmIcon = 49

	dtCenter     = 0x00000001
	dtVCenter    = 0x00000004
	dtSingleLine = 0x00000020

	transparent = 1
	fwBold      = 700
	antialiasedQuality = 4
	defaultCharset     = 1

	biRGB       = 0
	dibRGBColors = 0

	seeMaskNoCloseProcess = 0x00000040
	swHide                = 0
	infinite              = 0xFFFFFFFF
	errorAlreadyExists    = 183
	errorCancelled        = 1223
)

type wndClassExW struct {
	CbSize        uint32
	Style         uint32
	LpfnWndProc   uintptr
	CbClsExtra    int32
	CbWndExtra    int32
	HInstance     syscall.Handle
	HIcon         syscall.Handle
	HCursor       syscall.Handle
	HbrBackground syscall.Handle
	LpszMenuName  *uint16
	LpszClassName *uint16
	HIconSm       syscall.Handle
}

type point struct{ X, Y int32 }

type msg struct {
	HWnd    syscall.Handle
	Message uint32
	WParam  uintptr
	LParam  uintptr
	Time    uint32
	Pt      point
}

type guid struct {
	Data1 uint32
	Data2 uint16
	Data3 uint16
	Data4 [8]byte
}

// Layout must match NOTIFYICONDATAW exactly (976 bytes on amd64).
type notifyIconData struct {
	CbSize           uint32
	_                uint32
	HWnd             syscall.Handle
	UID              uint32
	UFlags           uint32
	UCallbackMessage uint32
	_                uint32
	HIcon            syscall.Handle
	SzTip            [128]uint16
	DwState          uint32
	DwStateMask      uint32
	SzInfo           [256]uint16
	UVersion         uint32
	SzInfoTitle      [64]uint16
	DwInfoFlags      uint32
	GuidItem         guid
	HBalloonIcon     syscall.Handle
}

type rect struct{ Left, Top, Right, Bottom int32 }

type bitmapInfoHeader struct {
	BiSize          uint32
	BiWidth         int32
	BiHeight        int32
	BiPlanes        uint16
	BiBitCount      uint16
	BiCompression   uint32
	BiSizeImage     uint32
	BiXPelsPerMeter int32
	BiYPelsPerMeter int32
	BiClrUsed       uint32
	BiClrImportant  uint32
}

type bitmapInfo struct {
	Header bitmapInfoHeader
	Colors [1]uint32
}

type iconInfo struct {
	FIcon    int32
	_        uint32
	XHotspot uint32
	YHotspot uint32
	HbmMask  syscall.Handle
	HbmColor syscall.Handle
}

type shellExecuteInfo struct {
	CbSize       uint32
	FMask        uint32
	Hwnd         syscall.Handle
	LpVerb       *uint16
	LpFile       *uint16
	LpParameters *uint16
	LpDirectory  *uint16
	NShow        int32
	HInstApp     syscall.Handle
	LpIDList     uintptr
	LpClass      *uint16
	HkeyClass    syscall.Handle
	DwHotKey     uint32
	HIcon        syscall.Handle
	HProcess     syscall.Handle
}

func utf16Ptr(s string) *uint16 {
	p, err := syscall.UTF16PtrFromString(s)
	if err != nil {
		return nil
	}
	return p
}

func copyTip(dst *[128]uint16, s string) {
	runes := syscall.StringToUTF16(s)
	if len(runes) > len(dst) {
		runes = runes[:len(dst)-1]
		runes = append(runes, 0)
	}
	for i := range dst {
		dst[i] = 0
	}
	copy(dst[:], runes)
}

// runElevated runs an executable via the "runas" verb and waits for it.
// Returns the exit code, and cancelled=true when the user declined UAC.
func runElevated(exe, args string) (exitCode uint32, cancelled bool, err error) {
	info := shellExecuteInfo{
		FMask:        seeMaskNoCloseProcess,
		LpVerb:       utf16Ptr("runas"),
		LpFile:       utf16Ptr(exe),
		LpParameters: utf16Ptr(args),
		NShow:        swHide,
	}
	info.CbSize = uint32(unsafe.Sizeof(info))
	ret, _, callErr := procShellExecuteExW.Call(uintptr(unsafe.Pointer(&info)))
	if ret == 0 {
		if errno, ok := callErr.(syscall.Errno); ok && uintptr(errno) == errorCancelled {
			return 0, true, nil
		}
		return 0, false, callErr
	}
	if info.HProcess != 0 {
		procWaitForSingleObject.Call(uintptr(info.HProcess), infinite)
		var code uint32
		procGetExitCodeProcess.Call(uintptr(info.HProcess), uintptr(unsafe.Pointer(&code)))
		procCloseHandle.Call(uintptr(info.HProcess))
		return code, false, nil
	}
	return 0, false, nil
}

func messageBox(text, title string, flags uintptr) uintptr {
	ret, _, _ := procMessageBoxW.Call(0,
		uintptr(unsafe.Pointer(utf16Ptr(text))),
		uintptr(unsafe.Pointer(utf16Ptr(title))),
		flags|mbSetForeground|mbTopMost)
	return ret
}
