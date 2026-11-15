/ ndprog: run by ndhook at segment 0x32, on the BIOS's stack.
	.globl	SS
SS	=	0x3f3f
	.shri
	.globl	start, pmain_
start:
	call	pmain_
1:
	jr	1b
