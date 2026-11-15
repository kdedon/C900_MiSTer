/ LANCE card check for tb_core (+lance), run from the reset PC 0x0038 in
/ place of the BIOS.  Sends a 32-byte frame (loopback takes 8 to 32,
/ TM p.1-24) to its own station address, read from the card's PROM,
/ through rings in RAM: in external loopback (the transceiver echoes the
/ cable), then in internal loopback.  The card is a bus master on
/ physical addresses: 08xxxx is logical 08:xxxx.  The vectored interrupt
/ goes through the PSA at 08:0000; the handler collects CSR0, clears it
/ and keeps the identifier word.
/ Results, five words per run from 08:0F00: CSR0 bits seen, RMD1, RMD3,
/ wrong data words, identifier; then 0xC0DE.
/ lance.patch: as-z8001 -o lance.o lance.s, then
/ hrtests/o2patch.py lance.o lance.patch.
MMU	=	0x00FC
RDP	=	0x0700
RAP	=	0x0702
PROM	=	0x0710
start:
	ldl	rr14, $0x08001000
	ld	r0, $0x9e00
	ldctl	REFRESH, r0
/ descriptors: 00 -> 0000, 08 -> 0800
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
	ld	r0, $0xC000
	ldctl	FCW, r0
/ PSA at 08:0000: VI FCW, and vector 88's PC at 014C
	ld	r0, $0x8800
	ldctl	PSAPSEG, r0
	ld	r0, $0
	ldctl	PSAPOFF, r0
	ldl	rr2, $0x0800003A
	ld	@rr2, $0xC000
	ldl	rr2, $0x0800014C
	ldar	r0, vi
	ld	@rr2, r0
	inc	r3, $2
	ld	@rr2, r1
/ the frame at 08:4000: our address twice, type 0800, a word pattern
	ldl	rr2, $0x08004000
	ldl	rr6, $0x08002002
	ld	r5, $3
	ld	r4, $PROM
1:	in	r0, @r4
	ld	@rr2, r0
	ld	r8, r3
	add	r8, $6
	ldl	rr10, rr2
	ld	r11, r8
	ld	@rr10, r0
	ldb	rh1, rl0
	ldb	rl1, rh0
	ld	@rr6, r1
	inc	r3, $2
	inc	r7, $2
	inc	r4, $2
	djnz	r5, 1b
	ldl	rr2, $0x0800400C
	ld	@rr2, $0x0800
	ld	r5, $9
	ld	r1, $0x1234
1:	inc	r3, $2
	ld	@rr2, r1
	add	r1, $0x3579
	djnz	r5, 1b
/ the rest of the init block: LADRF 0, one receive and one transmit entry
	ldl	rr2, $0x08002008
	ld	r5, $4
1:	ld	@rr2, $0
	inc	r3, $2
	djnz	r5, 1b
	ld	@rr2, $0x2100
	inc	r3, $2
	ld	@rr2, $0x0008
	inc	r3, $2
	ld	@rr2, $0x2200
	inc	r3, $2
	ld	@rr2, $0x0008
/ external, then internal loopback
	ldl	rr8, $0x08000F00
	ld	r4, $0x0004
	calr	run
	ld	r4, $0x0044
	calr	run
	ld	r0, $0xC0DE
	ld	@rr8, r0
park:
	jr	park
/ one frame with MODE r4; results to rr8 on
run:
	ldl	rr2, $0x08002000
	ld	@rr2, r4
	ldl	rr2, $0x08002100
	ld	@rr2, $0x3000
	inc	r3, $2
	ld	@rr2, $0x8008
	inc	r3, $2
	ld	@rr2, $0xFF00
	inc	r3, $2
	ld	@rr2, $0
	ldl	rr2, $0x08002200
	ld	@rr2, $0x4000
	inc	r3, $2
	ld	@rr2, $0x8308
	inc	r3, $2
	ld	@rr2, $0xFFE0
	inc	r3, $2
	ld	@rr2, $0
	ldl	rr2, $0x08003000
	ld	r5, $32
1:	ld	@rr2, $0
	inc	r3, $2
	djnz	r5, 1b
	ldl	rr2, $0x08000E00
	ld	@rr2, $0
	inc	r3, $2
	ld	@rr2, $0
	inc	r3, $2
	ld	@rr2, $0
/ STOP, CSR1-3, INIT, wait for IDON, STRT
	ld	r0, $0
	out	RAP, r0
	ld	r0, $0x0004
	out	RDP, r0
	ld	r0, $1
	out	RAP, r0
	ld	r0, $0x2000
	out	RDP, r0
	ld	r0, $2
	out	RAP, r0
	ld	r0, $0x0008
	out	RDP, r0
	ld	r0, $3
	out	RAP, r0
	ld	r0, $0x0007
	out	RDP, r0
	ld	r0, $0
	out	RAP, r0
	ld	r0, $0x0041
	out	RDP, r0
1:	in	r0, RDP
	bit	r0, $8
	jr	z, 1b
	ld	r0, $0x0142
	out	RDP, r0
/ interrupts on, TDMD, wait for TINT and RINT
	ld	r0, $0xD000
	ldctl	FCW, r0
	ld	r0, $0x0048
	out	RDP, r0
	ldl	rr2, $0x08000E00
	ld	r5, $0xFFFF
1:	ld	r0, @rr2
	and	r0, $0x0600
	cp	r0, $0x0600
	jr	z, 2f
	djnz	r5, 1b
2:	ld	r0, $0xC000
	ldctl	FCW, r0
/ results
	ld	r0, @rr2
	ld	@rr8, r0
	inc	r9, $2
	ldl	rr2, $0x08002102
	ld	r0, @rr2
	ld	@rr8, r0
	inc	r9, $2
	ldl	rr2, $0x08002106
	ld	r0, @rr2
	ld	@rr8, r0
	inc	r9, $2
	ld	r6, $0
	ldl	rr2, $0x08003000
	ldl	rr10, $0x08004000
	ld	r5, $16
1:	ld	r0, @rr2
	cp	r0, @rr10
	jr	z, 3f
	inc	r6, $1
3:	inc	r3, $2
	inc	r11, $2
	djnz	r5, 1b
	ld	@rr8, r6
	inc	r9, $2
	ldl	rr2, $0x08000E04
	ld	r0, @rr2
	ld	@rr8, r0
	inc	r9, $2
	ret
/ vectored interrupt: CSR0 into 08:0E00, a count at 0E02, the identifier at 0E04
vi:
	pushl	@rr14, rr2
	pushl	@rr14, rr0
	ldl	rr2, rr14
	inc	r3, $8
	ld	r0, @rr2
	ldl	rr2, $0x08000E04
	ld	@rr2, r0
	in	r0, RDP
	out	RDP, r0
	ldl	rr2, $0x08000E00
	ld	r1, @rr2
	or	r1, r0
	ld	@rr2, r1
	inc	r3, $2
	inc	@rr2, $1
	popl	rr0, @rr14
	popl	rr2, @rr14
	iret
/ four descriptor bytes: base r0, limit FF, attributes 00 (SAR increments)
desc:
	soutb	MMU+0x0F00, rh0
	soutb	MMU+0x0F00, rl0
	soutb	MMU+0x0F00, rh1
	soutb	MMU+0x0F00, rl1
	ret
