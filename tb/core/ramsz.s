/ RAM map check for tb_core, run from the reset PC 0x0038 in place of the
/ BIOS.  Logical segment 10 is mapped in turn to each physical segment
/ 08-FF; 0x5A00 + segment is written to its offset 8000, then every
/ segment is read back into 08:2010-21FE (word per segment), and 0xC0DE
/ goes to 08:0F08.  Empty segments read FFFF.
/ ramsz.patch: as-z8001 -o ramsz.o ramsz.s, then
/ hrtests/o2patch.py ramsz.o ramsz.patch.
MMU	=	0x00FC
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
/ writes
	ld	r7, $0x0008
1:	calr	map
	ld	r4, r7
	add	r4, $0x5A00
	ldl	rr10, $0x10008000
	ld	@rr10, r4
	inc	r7, $1
	cp	r7, $0x0100
	jr	nz, 1b
/ reads
	ld	r7, $0x0008
	ldl	rr2, $0x08002010
1:	calr	map
	ldl	rr10, $0x10008000
	ld	r4, @rr10
	ld	@rr2, r4
	inc	r3, $2
	inc	r7, $1
	cp	r7, $0x0100
	jr	nz, 1b
	ldl	rr2, $0x08000F08
	ld	r0, $0xC0DE
	ld	@rr2, r0
park:
	jr	park
/ segment 10 -> physical segment r7
map:
	ldb	rl0, $0x10
	soutb	MMU+0x0100, rl0
	ldb	rh0, rl7
	ldb	rl0, $0x00
/ four descriptor bytes: base r0, limit FF, attributes 00
desc:
	soutb	MMU+0x0F00, rh0
	soutb	MMU+0x0F00, rl0
	soutb	MMU+0x0F00, rh1
	soutb	MMU+0x0F00, rl1
	ret
