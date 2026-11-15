/ ndhook: loaded by the BIOS at segment 0x30, on the BIOS's stack.
	.globl	SS
SS	=	0x3f3f
	.shri
	.globl	start, hmain_
start:
	call	hmain_
1:
	jr	1b

	.globl	mapseg_, inw_, outw_, inir_
mapseg_:
	ld	r0, rr14(4)
	ld	r1, rr14(6)
	ld	r2, rr14(8)
	soutb	0x01fc, rl0
	soutb	0x0ffc, rh1
	soutb	0x0ffc, rl1
	ldb	rl3, $0xff
	soutb	0x0ffc, rl3
	soutb	0x0ffc, rl2
	ret
inw_:
	ld	r1, rr14(4)
	in	r1, @r1
	ret
outw_:
	ld	r1, rr14(4)
	ld	r0, rr14(6)
	out	@r1, r0
	ret
inir_:
	ldl	rr2, rr14(4)
	ld	r4, rr14(8)
	ld	r1, rr14(10)
	test	r1
	ret	z
	inir	@rr2, @r4, r1
	ret
