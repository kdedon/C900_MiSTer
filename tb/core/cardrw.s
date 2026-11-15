/ Card read/write check for tb_core, run from the reset PC 0x0038 in place
/ of the BIOS.  Writes and reads back the LR character RAM (37:0000), the
/ HR bitmap (3A:0000, mapped to 3E:0000), the HR ports (control 0404H
/ written, mouse 0400H/0402H/0410H read twice) and the LC 8563 R12/R13.
/ Words: each written and read at once, then all read again; bytes at
/ odd addresses (LR: the character lane), HR also at even ones.  The
/ wrong reads per part go to 08:0F00 (LR), 0F02 (HR), 0F04 (HR ports),
/ 0F06 (LC), then 0xC0DE to 0F08.  An absent card reads FF: the bench
/ checks only the fitted card's count.
/ cardrw.patch: as-z8001 -o cardrw.o cardrw.s, then
/ hrtests/o2patch.py cardrw.o cardrw.patch.
MMU	=	0x00FC
VA	=	0x0181
VD	=	0x0183
start:
	ldl	rr14, $0x08001000
	ld	r0, $0x9e00
	ldctl	REFRESH, r0
/ descriptors: 00 -> 0000, 08 -> 0800, 37 -> 3700, 3A -> 3E00, 3B -> 3F00
	ld	r1, $0xFF00
	ldb	rl0, $0x00
	soutb	MMU+0x0100, rl0
	ld	r0, $0x0000
	calr	desc
	ldb	rl0, $0x08
	soutb	MMU+0x0100, rl0
	ld	r0, $0x0800
	calr	desc
	ldb	rl0, $0x37
	soutb	MMU+0x0100, rl0
	ld	r0, $0x3700
	calr	desc
	ldb	rl0, $0x3A
	soutb	MMU+0x0100, rl0
	ld	r0, $0x3E00
	calr	desc
	ld	r0, $0x3F00
	calr	desc
	ldb	rl0, $0xC0
	soutb	MMU+0x0000, rl0
	ld	r0, $0xC000
	ldctl	FCW, r0
/ LR character RAM
	ld	r12, $0
	ldl	rr10, $0x37000000
	calr	words
	ldl	rr10, $0x37000001
	calr	bytes
	ld	r4, r12
/ HR bitmap
	ld	r12, $0
	ldl	rr10, $0x3A000000
	calr	words
	ldl	rr10, $0x3A001001
	calr	bytes
	ldl	rr10, $0x3A002000
	calr	bytes
	ld	r5, r12
/ HR ports
	ld	r6, $0
	ldb	rl0, $0xFF
	outb	0x0404, rl0
	in	r0, 0x0400
	in	r1, 0x0400
	cp	r0, r1
	jr	z, 1f
	inc	r6, $1
1:	in	r0, 0x0402
	in	r1, 0x0402
	cp	r0, r1
	jr	z, 1f
	inc	r6, $1
1:	in	r0, 0x0410
	in	r1, 0x0410
	cp	r0, r1
	jr	z, 1f
	inc	r6, $1
/ LC R12/R13
1:	ld	r7, $0
	ldb	rl0, $12
	outb	VA, rl0
	ldb	rl0, $0x5A
	outb	VD, rl0
	ldb	rl0, $13
	outb	VA, rl0
	ldb	rl0, $0xA5
	outb	VD, rl0
	ldb	rl0, $12
	outb	VA, rl0
	inb	rl1, VD
	cpb	rl1, $0x5A
	jr	z, 1f
	inc	r7, $1
1:	ldb	rl0, $13
	outb	VA, rl0
	inb	rl1, VD
	cpb	rl1, $0xA5
	jr	z, 1f
	inc	r7, $1
/ results
1:	ldl	rr2, $0x08000F00
	ld	@rr2, r4
	inc	r3, $2
	ld	@rr2, r5
	inc	r3, $2
	ld	@rr2, r6
	inc	r3, $2
	ld	@rr2, r7
	inc	r3, $2
	ld	r0, $0xC0DE
	ld	@rr2, r0
park:
	jr	park
/ 256 words from rr10: written and read back one by one, then all read
/ again; wrong reads added to r12
words:
	pushl	@rr14, rr10
	ld	r2, $256
	ld	r1, $0x1234
1:	ld	@rr10, r1
	ld	r3, @rr10
	cp	r3, r1
	jr	z, 2f
	inc	r12, $1
2:	add	r1, $0x3579
	inc	r11, $2
	djnz	r2, 1b
	popl	rr10, @rr14
	ld	r2, $256
	ld	r1, $0x1234
1:	ld	r3, @rr10
	cp	r3, r1
	jr	z, 2f
	inc	r12, $1
2:	add	r1, $0x3579
	inc	r11, $2
	djnz	r2, 1b
	ret
/ 256 bytes from rr10, every other address, as words
bytes:
	pushl	@rr14, rr10
	ld	r2, $256
	ldb	rl1, $0x5A
1:	ldb	@rr10, rl1
	ldb	rl3, @rr10
	cpb	rl3, rl1
	jr	z, 2f
	inc	r12, $1
2:	addb	rl1, $0x3B
	inc	r11, $2
	djnz	r2, 1b
	popl	rr10, @rr14
	ld	r2, $256
	ldb	rl1, $0x5A
1:	ldb	rl3, @rr10
	cpb	rl3, rl1
	jr	z, 2f
	inc	r12, $1
2:	addb	rl1, $0x3B
	inc	r11, $2
	djnz	r2, 1b
	ret
/ four descriptor bytes: base r0, limit FF, attributes 00 (SAR increments)
desc:
	soutb	MMU+0x0F00, rh0
	soutb	MMU+0x0F00, rl0
	soutb	MMU+0x0F00, rh1
	soutb	MMU+0x0F00, rl1
	ret
