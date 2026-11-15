/ HR bitmap read-modify-write stress for tb_core +hr, run from the reset PC
/ 0x0038 in place of the BIOS.  The MMU maps logical 0x3A/0x3B to the bitmap
/ at 0x3E/0x3F as the kernel does.  Byte and word XOR at four bus phases, an
/ NVI between a read and its write, long and multiple-register moves, block
/ moves bitmap to bitmap, memory RMW instructions; refresh on.
/ hr_rmw.patch: as-z8001 -o hr_rmw.o hr_rmw.s, then the text (file offset
/ 0x30) as "<image offset> <byte>" lines: word at A -> A/2 (U17) and
/ 0x4000 + A/2 (U18), A from 0x38.
MMU	=	0x00FC
BASE	=	0x38
start:
	ldl	rr14, $0x08001000
	ld	r0, $0x9e00
	ldctl	REFRESH, r0
/ descriptors: 00 -> 0000, 08 -> 0800, 3A -> 3E00, 3B -> 3F00
	ld	r1, $0xFF00
	ldb	rl0, $0x00
	soutb	MMU+0x0100, rl0
	ld	r0, $0x0000
	calr	desc
	ldb	rl0, $0x08
	soutb	MMU+0x0100, rl0
	ld	r0, $0x0800
	calr	desc
	ldb	rl0, $0x3A
	soutb	MMU+0x0100, rl0
	ld	r0, $0x3E00
	calr	desc
	ld	r0, $0x3F00
	calr	desc
	ldb	rl0, $0xC0
	soutb	MMU+0x0000, rl0
/ program status area at 08:0000, NVI entry -> nvi
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
	ld	r0, $nvi+BASE
	ld	@rr2, r0
	ld	r0, $0x0800
	ldctl	PSAPSEG, r0
	ld	r0, $0
	ldctl	PSAPOFF, r0
	ld	r0, $0xC800
	ldctl	FCW, r0
/ 1. word fill, 0x3A:0000-0FFF
	ldl	rr10, $0x3A000000
	ld	r2, $2048
	ld	r1, $0x1234
fill:
	ld	@rr10, r1
	add	r1, $0x3579
	inc	r11, $2
	djnz	r2, fill
/ 2. byte XOR 0xA5 twice at four bus phases (no net change)
	ldl	rr10, $0x3A000000
	ld	r2, $256
bx0:
	ldb	rl1, @rr10
	xorb	rl1, $0xA5
	ldb	@rr10, rl1
	inc	r11, $1
	djnz	r2, bx0
	ldl	rr10, $0x3A000000
	ld	r2, $256
bx1:
	ldb	rl1, @rr10
	nop
	xorb	rl1, $0xA5
	ldb	@rr10, rl1
	inc	r11, $1
	djnz	r2, bx1
	ldl	rr10, $0x3A000100
	ld	r2, $256
bx2:
	ldb	rl1, @rr10
	nop
	nop
	xorb	rl1, $0xA5
	ldb	@rr10, rl1
	inc	r11, $1
	djnz	r2, bx2
	ldl	rr10, $0x3A000100
	ld	r2, $256
bx3:
	ldb	rl1, @rr10
	nop
	nop
	nop
	xorb	rl1, $0xA5
	ldb	@rr10, rl1
	inc	r11, $1
	djnz	r2, bx3
/ 3. word XOR with an NVI after the read, after the XOR, after the write
	ldl	rr10, $0x3A000200
	ld	r2, $128
wx0:
	ld	r1, @rr10
	out	0x0202, r0
	xor	r1, $0xFFFF
	ld	@rr10, r1
	inc	r11, $2
	djnz	r2, wx0
	ldl	rr10, $0x3A000300
	ld	r2, $128
wx1:
	out	0x0202, r0
	ld	r1, @rr10
	xor	r1, $0x0FF0
	ld	@rr10, r1
	inc	r11, $2
	djnz	r2, wx1
	ldl	rr10, $0x3A000400
	ld	r2, $128
wx2:
	ldb	rl1, @rr10
	xorb	rl1, $0x3C
	out	0x0202, r0
	ldb	@rr10, rl1
	inc	r11, $1
	djnz	r2, wx2
/ 4. long and multiple-register RMW
	ldl	rr10, $0x3A000802
	ld	r6, $256
lx:
	ldl	rr2, @rr10
	xor	r2, $0x0F0F
	ldl	@rr10, rr2
	inc	r11, $4
	djnz	r6, lx
	ldl	rr10, $0x3A000C00
	ld	r7, $64
mx:
	ldm	r0, @rr10, $6
	com	r3
	ldm	@rr10, r0, $6
	inc	r11, $12
	djnz	r7, mx
/ 5. block moves bitmap to bitmap (scroll)
	ldl	rr2, $0x3A000000
	ldl	rr4, $0x3A002000
	ld	r0, $2048
	ldir	@rr4, @rr2, r0
	ldl	rr2, $0x3A000001
	ldl	rr4, $0x3A004003
	ld	r0, $1001
	ldirb	@rr4, @rr2, r0
	ldl	rr2, $0x3A000FFE
	ldl	rr4, $0x3B000FFE
	ld	r0, $2048
	lddr	@rr4, @rr2, r0
/ 6. memory RMW instructions
	ldl	rr10, $0x3A006000
	ld	r2, $256
rw:
	com	@rr10
	inc	@rr10, $3
	inc	r11, $2
	djnz	r2, rw
	ldl	rr10, $0x3A006800
	ld	r2, $256
rb:
	comb	@rr10
	incb	@rr10, $5
	inc	r11, $1
	djnz	r2, rb
park:
	jr	park
/ four descriptor bytes: base r0, limit FF, attributes 00 (SAR increments)
desc:
	soutb	MMU+0x0F00, rh0
	soutb	MMU+0x0F00, rl0
	soutb	MMU+0x0F00, rh1
	soutb	MMU+0x0F00, rl1
	ret
nvi:
	iret
