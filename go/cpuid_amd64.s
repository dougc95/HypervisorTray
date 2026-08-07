#include "textflag.h"

// func cpuidECX1() uint32
// Returns ECX from CPUID leaf 1; bit 31 is the hypervisor-present bit.
TEXT ·cpuidECX1(SB), NOSPLIT, $0-4
	MOVL $1, AX
	MOVL $0, CX
	CPUID
	MOVL CX, ret+0(FP)
	RET
