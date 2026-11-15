/ SCC U74 channel B transmit check for tb_core, run from the reset PC
/ 0x0038 in place of the BIOS: COHERENT's sccinit after All Sent (WR4 4C,
/ WR11 56, WR12 11, WR13 00, WR14 03, WR3 C1, WR5 EA), then "U900\r\n",
/ each byte after Tx Buffer Empty.  The bench decodes the TxD pin.
/ sertx.patch: as-z8001 -o sertx.o sertx.s, then
/ hrtests/o2patch.py sertx.o sertx.patch.  No stack: no calls.
start:
1:	inb	rl1, 0x0103
	bitb	rl1, $0
	jr	z, 1b
	ldb	rl0, $0x4C
	outb	0x0109, rl0
	ldb	rl0, $0x56
	outb	0x0117, rl0
	ldb	rl0, $0x11
	outb	0x0119, rl0
	ldb	rl0, $0x00
	outb	0x011B, rl0
	ldb	rl0, $0x03
	outb	0x011D, rl0
	ldb	rl0, $0xC1
	outb	0x0107, rl0
	ldb	rl0, $0xEA
	outb	0x010B, rl0
	ldb	rl0, $0x55
	ldb	rh0, $0x39
	ldb	rl2, $0x30
	ldb	rh2, $0x30
	ldb	rl3, $0x0D
	ldb	rh3, $0x0A
	ld	r4, $6
2:	inb	rl1, 0x0101
	bitb	rl1, $2
	jr	z, 2b
	outb	0x0111, rl0
	ldb	rl0, rh0
	ldb	rh0, rl2
	ldb	rl2, rh2
	ldb	rh2, rl3
	ldb	rl3, rh3
	djnz	r4, 2b
park:
	jr	park
