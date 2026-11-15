/ LANCE card boot ROM: header, entry and machine glue.
/
/ The image is the text, padded to 1 KB (a segment base's A9:A8 come
/ from the offset), then the initialised data.  mkcardrom.py fills the length, the checksum and the text pages.
/
/ Header, words: "C9NR", version, length in words, entry offset, text
/ segment, flags, checksum (all words of the image sum to 0); then the
/ text pages, ours.
/
/ The BIOS maps the text segment onto the copy and calls init(rp, jt,
/ work), work being the copy's page (physical address / 256).  init maps
/ the data segment past the text and goes on in C.
/
/ init, open, read and info run on the card's own stack, from the end of
/ its 36 KB down; the C9JT services run back on the BIOS's.  The
/ compiler addresses frames in segment SS, so SS is the data segment.
	.globl	SS
SS	=	0x2929
	.shri
	.globl	init_, ndopen_, ndread_, ndinfo_, jtcall_, tpages_
	.globl	cinit_, copen_, cread_, cinfo_, jt_
	.ascii	"C9NR"
	.word	1
	.word	0
	.word	init_
	.word	0x28
	.word	0
	.word	0
tpages_:
	.word	0

init_:
	ld	r1, rr14(12)		/ work
	add	r1, tpages_
	ldb	rl0, $0x29
	soutb	0x01fc, rl0
	soutb	0x0ffc, rh1
	soutb	0x0ffc, rl1
	ldb	rl0, $0xff
	soutb	0x0ffc, rl0
	ldb	rl0, $0x02		/ SYS, writable
	soutb	0x0ffc, rl0
	ld	r0, $0x90		/ the 36 KB end, in pages past the data
	sub	r0, tpages_
	sll	r0, $8
	ld	stop_, r0
	lda	rr4, cinit_
	jr	enter
ndopen_:
	lda	rr4, copen_
	jr	enter
ndread_:
	lda	rr4, cread_
	jr	enter
ndinfo_:
	lda	rr4, cinfo_
	jr	enter

/ Call rr4 on the card's stack with the caller's first 10 bytes of
/ arguments.  R0-R5 are the only registers a callee may change.
enter:
	ldl	fn_, rr4
	ldl	rr2, rr14
	ldl	bsp_, rr14
	inc	r3, $4
	ld	r14, $0x2900
	ld	r15, stop_
	dec	r15, $10
	ldl	rr4, rr14
	ld	r1, $5
	ldir	@rr4, @rr2, r1
	ldl	rr4, fn_
	call	@rr4
	ldl	rr14, bsp_
	ret

/ jtcall(n, a): C9JT service n with a 4-byte argument (or two words),
/ on the BIOS's stack.
jtcall_:
	ld	r1, rr14(4)
	sll	r1, $3
	add	r1, $16
	ldl	rr4, jt_
	add	r5, r1
	ldl	rr2, rr14(6)
	ldl	csp_, rr14
	ldl	rr14, bsp_
	pushl	@rr14, rr2
	call	@rr4
	ldl	rr14, csp_
	ret

	.prvd
stop_:
	.word	0
bsp_:
	.long	0
csp_:
	.long	0
fn_:
	.long	0

	.shri

/ mapseg(seg, page, attr): one Z8010 descriptor, the whole segment.
	.globl	mapseg_
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

	.globl	inw_, outw_, inb_, outb_, inir_, copy_
inw_:
	ld	r1, rr14(4)
	in	r1, @r1
	ret
outw_:
	ld	r1, rr14(4)
	ld	r0, rr14(6)
	out	@r1, r0
	ret
inb_:
	ld	r1, rr14(4)
	inb	rl1, @r1
	subb	rh1, rh1
	ret
outb_:
	ld	r1, rr14(4)
	ld	r0, rr14(6)
	outb	@r1, rl0
	ret

/ inir(dst, port, n): n words from one port.
inir_:
	ldl	rr2, rr14(4)
	ld	r4, rr14(8)
	ld	r1, rr14(10)
	test	r1
	ret	z
	inir	@rr2, @r4, r1
	ret

/ copy(dst, src, n): n bytes.
copy_:
	ldl	rr4, rr14(4)
	ldl	rr2, rr14(8)
	ld	r1, rr14(12)
	test	r1
	ret	z
	ldirb	@rr4, @rr2, r1
	ret
