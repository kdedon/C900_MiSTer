start:
	ldl	rr14, $0x08001000
	ldl	rr2, $0x08000000
	ld	r0, $0
	ld	@rr2, r0
	inc	r3, $2
	ld	r0, $0x4000
	ld	@rr2, r0
	inc	r3, $2
	ld	r0, $0x8000
	ld	@rr2, r0
	inc	r3, $2
	ld	r0, $handler+0x38
	ld	@rr2, r0
	ldl	rr2, $0x08000030
	ld	r0, $0
	ld	@rr2, r0
	inc	r3, $2
	ld	r0, $0xC000
	ld	@rr2, r0
	inc	r3, $2
	ld	r0, $0x8000
	ld	@rr2, r0
	inc	r3, $2
	ld	r0, $handler+0x38
	ld	@rr2, r0
	ld	r0, $0x0800
	ldctl	PSAPSEG, r0
	ld	r0, $0
	ldctl	PSAPOFF, r0
	ld	r0, $0
	ld	r9, $0
	ld	r0, $0xC800
	ldctl	FCW, r0
/ cursor at row 2 byte 0x10 (P0)
	ldl	rr12, $0x3E000110
	calr	merge
/ smgr-style small XOR: read the long holding the cursor's first row,
/ XOR a field beside it, write the long back; a tick lands in between
	ldl	rr10, $0x3E000110
	ldl	rr2, @rr10
	out	0x0202, r0
	nop
	nop
	xor	r3, $0x00F0
	nop
	ldl	@rr10, rr2
/ erase the cursor at its new place (P1)
	ldl	rr12, $0x3E000140
	calr	merge
2:
	jr	2b
/ hrmouse: erase at P0, draw at P1
handler:
	pushl	@rr14, rr12
	ldl	rr12, $0x3E000110
	calr	merge
	ldl	rr12, $0x3E000140
	calr	merge
	popl	rr12, @rr14
	iret
/ hrmerge: XOR a 3-byte x 8-row sprite at rr12
merge:
	pushl	@rr14, rr12
	ld	r8, $8
3:
	ldb	rl1, @rr12
	xorb	rl1, $0xFF
	ldb	@rr12, rl1
	inc	r13, $1
	ldb	rl1, @rr12
	xorb	rl1, $0xC3
	ldb	@rr12, rl1
	inc	r13, $1
	ldb	rl1, @rr12
	xorb	rl1, $0x81
	ldb	@rr12, rl1
	add	r13, $126
	djnz	r8, 3b
	popl	rr12, @rr14
	ret
