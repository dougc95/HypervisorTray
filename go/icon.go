//go:build windows

package main

import (
	"syscall"
	"unsafe"
)

// makeIcon draws the tray icon at the shell's small-icon size: a filled circle
// in the mode colour with a white letter, plus an optional gold dot marking a
// pending reboot. GDI text drawing ignores the alpha channel, so the alpha is
// written directly into the DIB before and after the text pass.
func makeIcon(letter string, r, g, b byte, pending bool) syscall.Handle {
	size, _, _ := procGetSystemMetrics.Call(smCXSmIcon)
	n := int32(size)
	if n < 16 {
		n = 16
	}

	memDC, _, _ := procCreateCompatibleDC.Call(0)
	if memDC == 0 {
		return 0
	}
	defer procDeleteDC.Call(memDC)

	bi := bitmapInfo{Header: bitmapInfoHeader{
		BiWidth:       n,
		BiHeight:      -n, // top-down
		BiPlanes:      1,
		BiBitCount:    32,
		BiCompression: biRGB,
	}}
	bi.Header.BiSize = uint32(unsafe.Sizeof(bi.Header))

	var bits unsafe.Pointer
	hbmColor, _, _ := procCreateDIBSection.Call(memDC,
		uintptr(unsafe.Pointer(&bi)), dibRGBColors,
		uintptr(unsafe.Pointer(&bits)), 0, 0)
	if hbmColor == 0 || bits == nil {
		return 0
	}
	defer procDeleteObject.Call(hbmColor)

	px := unsafe.Slice((*byte)(bits), int(n)*int(n)*4)

	centre := float64(n-1) / 2
	radius := float64(n) / 2
	inside := func(x, y int32) bool {
		dx := float64(x) - centre
		dy := float64(y) - centre
		return dx*dx+dy*dy <= (radius-0.5)*(radius-0.5)
	}

	// Dot occupies the lower-right corner when a reboot is pending.
	dotR := float64(n) * 0.19
	dotCX := float64(n) * 0.78
	dotCY := float64(n) * 0.78
	inDot := func(x, y int32) bool {
		if !pending {
			return false
		}
		dx := float64(x) - dotCX
		dy := float64(y) - dotCY
		return dx*dx+dy*dy <= dotR*dotR
	}

	for y := int32(0); y < n; y++ {
		for x := int32(0); x < n; x++ {
			i := (y*n + x) * 4
			switch {
			case inDot(x, y):
				px[i+0], px[i+1], px[i+2], px[i+3] = 0x00, 0xC0, 0xFF, 0xFF // gold (BGRA)
			case inside(x, y):
				px[i+0], px[i+1], px[i+2], px[i+3] = b, g, r, 0xFF
			default:
				px[i+0], px[i+1], px[i+2], px[i+3] = 0, 0, 0, 0
			}
		}
	}

	old, _, _ := procSelectObject.Call(memDC, hbmColor)

	height := -int32(float64(n) * 0.62)
	font, _, _ := procCreateFontW.Call(
		uintptr(height), 0, 0, 0, fwBold, 0, 0, 0,
		defaultCharset, 0, 0, antialiasedQuality, 0,
		uintptr(unsafe.Pointer(utf16Ptr("Segoe UI"))))
	oldFont, _, _ := procSelectObject.Call(memDC, font)

	procSetBkMode.Call(memDC, transparent)
	procSetTextColor.Call(memDC, 0x00FFFFFF) // white
	rc := rect{0, 0, n, n}
	procDrawTextW.Call(memDC,
		uintptr(unsafe.Pointer(utf16Ptr(letter))), ^uintptr(0),
		uintptr(unsafe.Pointer(&rc)),
		dtCenter|dtVCenter|dtSingleLine)

	procSelectObject.Call(memDC, oldFont)
	procDeleteObject.Call(font)
	procSelectObject.Call(memDC, old)

	// GDI wrote the glyph with alpha 0; the disc is opaque, so restore it.
	for y := int32(0); y < n; y++ {
		for x := int32(0); x < n; x++ {
			if inside(x, y) || inDot(x, y) {
				px[(y*n+x)*4+3] = 0xFF
			}
		}
	}

	hbmMask, _, _ := procCreateBitmap.Call(uintptr(n), uintptr(n), 1, 1, 0)
	defer procDeleteObject.Call(hbmMask)

	ii := iconInfo{
		FIcon:    1,
		HbmMask:  syscall.Handle(hbmMask),
		HbmColor: syscall.Handle(hbmColor),
	}
	hIcon, _, _ := procCreateIconIndirect.Call(uintptr(unsafe.Pointer(&ii)))
	return syscall.Handle(hIcon)
}
