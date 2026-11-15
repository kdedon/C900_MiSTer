/ LC card probe for tb_core +lc, run from the reset PC 0x0038 in place of
/ the BIOS: 8563 registers R12/R13 written and read back, one RAM byte
/ through R18/R19/R31, 01FB (unclaimed) written and read, then the ID byte.  The
/ LCMON lines carry the results.
/ lc_probe.patch: as-z8001 -o lc_probe.o lc_probe.s, then
/ hrtests/o2patch.py lc_probe.o lc_probe.patch.  No stack: no calls.
VA	=	0x0181
VD	=	0x0183
IVR	=	0x01FB
ID	=	0x01FF
start:
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
	ldb	rl0, $13
	outb	VA, rl0
	inb	rl1, VD
/ RAM byte 0x77 at 0x1234; status bit 7: the RAM access is done
	ldb	rl0, $18
	outb	VA, rl0
	ldb	rl0, $0x12
	outb	VD, rl0
	ldb	rl0, $19
	outb	VA, rl0
	ldb	rl0, $0x34
	outb	VD, rl0
	ldb	rl0, $31
	outb	VA, rl0
	ldb	rl0, $0x77
	outb	VD, rl0
1:	inb	rl1, VA
	bitb	rl1, $7
	jr	z, 1b
	ldb	rl0, $18
	outb	VA, rl0
	ldb	rl0, $0x12
	outb	VD, rl0
	ldb	rl0, $19
	outb	VA, rl0
	ldb	rl0, $0x34
	outb	VD, rl0
1:	inb	rl1, VA
	bitb	rl1, $7
	jr	z, 1b
	ldb	rl0, $31
	outb	VA, rl0
	inb	rl1, VD
/ glue
	ldb	rl0, $0x3C
	outb	IVR, rl0
	inb	rl1, IVR
	inb	rl1, ID
park:
	jr	park
