/ Single-step circuit test (spec 3.10) for tb_core, run from the reset PC
/ 0x0038 in place of the BIOS.  Each test arms the stepper, runs mixed-length
/ instructions and the NVI handler logs the interrupted PC.  Results: bit n of
/ the verdict word at 0x08000100 is set when check n fails; bit 15 = done
/ (0x8000 = all pass).  ssmon.sv logs the pin timing.
SSTEP	=	0x0203
LOG	=	0x08000200
MMU	=	0x00FC
start:
	ldl	rr14, $0x08001000
	ld	r1, $0xFF00
	ldb	rl0, $0x00
	soutb	MMU+0x0100, rl0
	ld	r0, $0x0000
	calr	desc
	ldb	rl0, $0x08
	soutb	MMU+0x0100, rl0
	ld	r0, $0x0800
	calr	desc
	ldb	rl0, $0xC0
	soutb	MMU+0x0000, rl0
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
	ldl	rr10, $LOG
	ld	r8, $0
	ld	r12, $0
	ld	r0, $0xC800
	ldctl	FCW, r0
	ldb	rl0, $0x55
/ A: OUTB arm, then 6-byte and 2-byte instructions
	outb	SSTEP, rl0
tA1:	nop
tA2:	ldl	rr2, $0x12345678
tA3:	ld	r3, $0x1234
	nop
	nop
	nop
	nop
/ B: INB arm
tB0:	inb	rl1, SSTEP
tB1:	ldl	rr2, $0x12345678
tB2:	nop
tB3:	ld	r3, $0x1234
	nop
	nop
	nop
	nop
/ C: word OUT at 0x0202
tC0:	out	0x0202, r0
tC1:	ld	r3, $0x1234
tC2:	inc	r4, $1
tC3:	ldl	rr2, $0x12345678
	nop
	nop
	nop
	nop
/ D: access at 0x0201 (A1 clear): spec says it arms
tD0:	outb	0x0201, rl0
	nop
	nop
	nop
	nop
	nop
	nop
/ E: the handler re-arms three times
	ld	r8, $3
tE0:	outb	SSTEP, rl0
	nop
	nop
tE3:	ld	r3, $0x1234
tE4:	ldl	rr2, $0x12345678
tE5:	inc	r4, $1
tE6:	nop
	nop
	nop
	nop
	nop
/ checks: log entries
	ldl	rr2, $LOG
	ld	r0, @rr2
	cp	r0, $tA3+0x38
	jr	eq, 1f
	set	r12, $0
1:	inc	r3, $2
	ld	r0, @rr2
	cp	r0, $tB3+0x38
	jr	eq, 1f
	set	r12, $1
1:	inc	r3, $2
	ld	r0, @rr2
	cp	r0, $tC3+0x38
	jr	eq, 1f
	set	r12, $2
1:	inc	r3, $2
	ld	r0, @rr2
	cp	r0, $tE3+0x38
	jr	eq, 1f
	set	r12, $3
1:	inc	r3, $2
	ld	r0, @rr2
	cp	r0, $tE4+0x38
	jr	eq, 1f
	set	r12, $4
1:	inc	r3, $2
	ld	r0, @rr2
	cp	r0, $tE5+0x38
	jr	eq, 1f
	set	r12, $5
1:	inc	r3, $2
	ld	r0, @rr2
	cp	r0, $tE6+0x38
	jr	eq, 1f
	set	r12, $6
1:	inc	r3, $2
/ log length: 7 entries
	ldl	rr2, $LOG+14
	cpl	rr10, rr2
	jr	eq, 1f
	set	r12, $7
1:	set	r12, $15
	ldl	rr2, $0x08000100
	ld	@rr2, r12
/ F: NVI disabled, arm, five instructions
	ld	r0, $0xC000
	ldctl	FCW, r0
	outb	SSTEP, rl0
	nop
	nop
	nop
	nop
	nop
	nop
2:	jr	2b
desc:
	soutb	MMU+0x0F00, rh0
	soutb	MMU+0x0F00, rl0
	soutb	MMU+0x0F00, rh1
	soutb	MMU+0x0F00, rl1
	ret
/ NVI: log the interrupted PC, re-arm while r8 != 0
handler:
	pop	r4, @rr14
	pop	r5, @rr14
	pop	r6, @rr14
	pop	r7, @rr14
	ld	@rr10, r7
	inc	r11, $2
	push	@rr14, r7
	push	@rr14, r6
	push	@rr14, r5
	push	@rr14, r4
	test	r8
	jr	z, 1f
	dec	r8, $1
	outb	SSTEP, rl0
1:	iret
