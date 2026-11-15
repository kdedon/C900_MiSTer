/*
 * ndhook: the BIOS hook's steps done by a loaded program.  Probes the
 * card's ROM window, copies the image to page rc_rsvd_seg:4000 with
 * INIR, checks the sum, maps it with the BIOS's segload and calls init
 * with a C9RC copy as long as the BIOS will make it.  Then:
 *   - nd.open of ndbig.bin, read whole to physical 0x100000 (two
 *     segments), one block past the end, an earlier block (a restart)
 *     and a later one;
 *   - nd.open of the configured file, an l.out loaded at 0x32/0x33 block
 *     by block, and a jump to it.
 * Prints NDHOOK FAIL and why on a failure.
 */
#include "nd.h"

#define ROMABI	0x029eL
#define HSVC(n)	((long (*)())(ROMABI + 16 + 8 * (n)))
#define CPAGE	0x26
#define WSEG	0x27
#define BIGPG	0x1000
#define PSEG	0x32
#define PCODE	0x1200
#define PDATA	0x1300

static char	rc[256], rc0[256];
static char	blk[512];
static char	hx[] = "0123456789abcdef";
static struct ndev *nd;

static
out(s)
char *s;
{
	(*HSVC(2))(s);
}

static
hex(v, n)
unsigned long v;
int n;
{
	char b[10];
	register int i;

	for (i = 0; i < n; i++)
		b[i] = hx[(int)(v >> 4 * (n - 1 - i)) & 15];
	b[n] = 0;
	out(b);
}

static
fail(s)
char *s;
{
	out("NDHOOK FAIL ");
	out(s);
	out("\n");
	for (;;)
		;
}

static unsigned long
gl(p)
register unsigned char *p;
{
	return ((unsigned long)p[1] << 24 | (unsigned long)p[0] << 16 | (unsigned)p[3] << 8 | p[2]);
}

static
rd(b, buf)
long b;
char *buf;
{
	return ((*nd->nd_read)(nd->nd_uoff, b, buf));
}

/* Block b against its copy at BIGPG. */
static
same(b)
long b;
{
	register int i;
	register char *p;

	if (rd(b, blk) != 1)
		return (0);
	mapseg(WSEG, BIGPG + (unsigned)(b >> 7 << 8), 0x02);
	p = DP(WSEG, (unsigned)b << 9);
	for (i = 0; i < 512; i++)
		if (blk[i] != p[i])
			return (0);
	return (1);
}

/* ndbig.bin: all of it, then past the end, a restart and a skip. */
static
big()
{
	register int i;
	register char *p;
	char *e;
	long b;
	unsigned sum;

	if ((e = (*nd->nd_open)("10.0.9.1:ndbig.bin")) != 0)
		fail(e);
	sum = 0;
	for (b = 0; ; b++) {
		if (b > 1000)
			fail("ndbig.bin does not end");
		mapseg(WSEG, BIGPG + (unsigned)(b >> 7 << 8), 0x02);
		p = DP(WSEG, (unsigned)b << 9);
		if (rd(b, p) != 1)
			break;
		for (i = 0; i < 512; i++)
			sum += p[i] & 0xff;
	}
	out("\nbig ");
	hex((unsigned long)b, 4);
	out(" blocks sum ");
	hex((unsigned long)sum, 4);
	out("\n");
	if (rd(100000L, blk) != 0)
		fail("read past the end");
	if (!same(3L) || !same(3L) || !same(6L))
		fail("restart");
	out("\nrestart ok\n");
}

/* The configured file: an l.out, loaded as the BIOS loads one. */
static
prog()
{
	register int i;
	register char *p;
	char *e;
	unsigned long tb, is, ds, bss, o, end, entry;
	long b;

	if ((e = (*nd->nd_open)("")) != 0)
		fail(e);
	out((*nd->nd_info)());
	out("\n");
	if (rd(0L, blk) != 1)
		fail("program header");
	if ((blk[0] & 0xff | blk[1] << 8) != 0407 || (blk[2] & 0x02) == 0)
		fail("not a separated l.out");
	tb = blk[6] & 0xff | (blk[7] & 0xff) << 8;
	is = gl(blk + 8) + gl(blk + 12);
	ds = gl(blk + 20) + gl(blk + 24);
	bss = gl(blk + 28);
	entry = gl(blk + 0x2c);
	if (is > 0xfc00L || ds + bss > 0xfc00L)
		fail("program too big");
	mapseg(PSEG, PCODE, 0x02);
	mapseg(PSEG + 1, PDATA, 0x02);
	end = tb + is + ds;
	for (o = tb, b = 0; o < end; o++) {
		if (o >> 9 != b) {
			b = o >> 9;
			if (rd(b, blk) != 1)
				fail("program short");
		}
		if (o < tb + is)
			p = DP(PSEG, (unsigned)(o - tb));
		else
			p = DP(PSEG + 1, (unsigned)(o - tb - is));
		*p = blk[(int)o & 511];
	}
	for (p = DP(PSEG + 1, (unsigned)ds), i = 0; i < bss; i++)
		*p++ = 0;
	(*HSVC(11))(PSEG, PCODE, PDATA);
	out("jump\n");
	(*(int (*)())entry)();
}

hmain()
{
	register int i;
	register unsigned *w;
	char **rv, *rp, *s;
	unsigned hdr[8], len, page, sum, n;

	out("NDHOOK\n");
	if (*(long *)ROMABI != 0x43394a54L)
		fail("no C9JT");
	rv = *(char ***)(ROMABI + 8);
	rp = rv[0];
	outw(ROMA, 0);
	for (i = 0; i < 8; i++)
		hdr[i] = inw(ROMD);
	if (hdr[0] != 0x4339 || hdr[1] != 0x4e52 || hdr[2] != 1 || hdr[3] > 0x2000)
		fail("no card ROM");
	len = hdr[3];
	page = ((rp[RC_RSVDSEG] & 0xff) << 8) + 0x40;
	mapseg(CPAGE, page, 0x02);
	outw(ROMA, 0);
	inir(DP(CPAGE, 0), ROMD, len);
	sum = 0;
	for (w = (unsigned *)DP(CPAGE, 0), i = 0; i < len; i++)
		sum += *w++;
	if (sum)
		fail("checksum");
	(*HSVC(11))(hdr[5], page, page);

	n = *(unsigned *)(rp + RC_LENGTH);
	if (n > sizeof rc)
		fail("romconf too long");
	for (s = rp, i = 0; i < n; i++)
		rc0[i] = rc[i] = s[i];
	nd = (struct ndev *)(*(long (*)())((long)hdr[5] << 24 | hdr[4]))(rc, (char *)ROMABI, page);
	if (nd == 0 || nd->nd_magic[0] != 'C' || nd->nd_magic[3] != 'D' || nd->nd_version != 1
	    || nd->nd_name[0] != 'n' || nd->nd_name[1] != 'd') {
		hex((unsigned long)nd, 8);
		out(" ");
		if (nd != 0)
			hex(*(unsigned long *)nd, 8);
		fail(" no device record");
	}
	out((*nd->nd_info)());
	out("\n");

	big();

	for (i = 0; i < n; i++)
		if (rc[i] != rc0[i])
			fail("romconf changed");
	out("romconf unchanged\n");

	prog();
	fail("program returned");
}
