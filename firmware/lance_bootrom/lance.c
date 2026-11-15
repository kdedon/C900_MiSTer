/*
 * Am7990, polled.  Init block, rings and buffers are in this ROM's bss;
 * the chip is given their physical addresses.  ARP requests for myip
 * are answered here.
 */
#include "nd.h"

#define INIT	0x0001		/* CSR0 */
#define STRT	0x0002
#define STOP	0x0004
#define TDMD	0x0008
#define MERR	0x0800
#define IDON	0x0100

#define OWN	0x8000		/* descriptor word 1 */
#define ERR	0x4000
#define STP	0x0200
#define ENP	0x0100

#define NRX	4
#define BUFSZ	1536

#define IB	0x0000
#define RDR	0x0020
#define TDR	0x0040
#define TBUF	0x0100
#define RBUF	0x0800
#define AREA	(RBUF + NRX * BUFSZ)

static char	lan[AREA + 8];
static unsigned	lo;		/* offset of the aligned area in lan */
static int	rxi;		/* next receive descriptor */
static int	held;		/* rxi holds a frame for the caller */
unsigned char	mymac[6];

static unsigned *
wp(off)
unsigned off;
{
	return ((unsigned *)&lan[lo + off]);
}

char *
tbuf()
{
	return (&lan[lo + TBUF]);
}

static long
phys(off)
unsigned off;
{
	return (physd((unsigned)(long)lan + lo + off));
}

static
csr(n, v)
unsigned n, v;
{
	outw(RAP, n);
	outw(RDP, v);
}

static unsigned
csr0()
{
	outw(RAP, 0);
	return (inw(RDP));
}

static
give(i)
int i;
{
	register unsigned *d;
	long a;

	d = wp(RDR + 8 * i);
	a = phys(RBUF + BUFSZ * i);
	d[0] = a;
	d[2] = -BUFSZ;
	d[3] = 0;
	d[1] = OWN | (unsigned)(a >> 16) & 0xff;
}

/* The MAC from the address PROM. */
lanmac()
{
	register int i;
	register unsigned w;

	for (i = 0; i < 3; i++) {
		w = inw(PROM + 2 * i);
		mymac[2 * i] = w >> 8;
		mymac[2 * i + 1] = w;
	}
}

/* Start the chip.  0 if it does not come up. */
lanup()
{
	register int i;
	register unsigned *ib;
	long a;

	lo = (8 - ((unsigned)(long)lan & 7)) & 7;
	lanmac();
	csr(0, STOP);
	csr(3, 0x0007);			/* BSWP, ACON, BCON */
	ib = wp(IB);
	ib[0] = 0;
	for (i = 0; i < 3; i++)
		ib[1 + i] = mymac[2 * i + 1] << 8 | mymac[2 * i];
	for (i = 4; i < 8; i++)
		ib[i] = 0;
	a = phys(RDR);
	ib[8] = a;
	ib[9] = 2 << 13 | (unsigned)(a >> 16) & 0xff;	/* 4 entries */
	a = phys(TDR);
	ib[10] = a;
	ib[11] = (unsigned)(a >> 16) & 0xff;		/* 1 entry */
	for (i = 0; i < NRX; i++)
		give(i);
	wp(TDR)[1] = 0;
	rxi = 0;
	held = 0;
	a = phys(IB);
	csr(1, (unsigned)a);
	csr(2, (unsigned)(a >> 16) & 0xff);
	csr(0, INIT);
	tstart();
	while ((csr0() & IDON) == 0)
		if (tnow() > 100 || (csr0() & MERR)) {
			csr(0, STOP);
			return (0);
		}
	csr(0, IDON);
	csr(0, STRT);
	return (1);
}

landown()
{
	csr(0, STOP);
}

/* Send the n-byte frame at tbuf(), padded to 60. */
xmit(n)
register int n;
{
	register unsigned *d;
	register char *b;
	long a;

	b = tbuf();
	for (; n < 60; n++)
		b[n] = 0;
	d = wp(TDR);
	a = phys(TBUF);
	d[0] = a;
	d[2] = -n;
	d[3] = 0;
	d[1] = OWN | STP | ENP | (unsigned)(a >> 16) & 0xff;
	csr(0, TDMD);
	tstart();
	while ((d[1] & OWN) && tnow() < 100)
		;
}

/* Ethernet header at tbuf() */
ether(dst, type)
register unsigned char *dst;
unsigned type;
{
	register char *b;
	register int i;

	b = tbuf();
	for (i = 0; i < 6; i++) {
		b[i] = dst[i];
		b[6 + i] = mymac[i];
	}
	b[12] = type >> 8;
	b[13] = type;
}

static unsigned char	bcast[6] = { 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };

/* ARP request (1) or reply (2) */
arp(op, tha, tpa)
int op;
unsigned char *tha, *tpa;
{
	static unsigned char hdr[8] = { 0, 1, 8, 0, 6, 4, 0, 0 };
	register char *b;
	register int i;

	ether(op == 1 ? bcast : tha, 0x0806);
	b = tbuf();
	hdr[7] = op;
	for (i = 0; i < 8; i++)
		b[14 + i] = hdr[i];
	for (i = 0; i < 6; i++) {
		b[22 + i] = mymac[i];
		b[32 + i] = op == 1 ? 0 : tha[i];
	}
	for (i = 0; i < 4; i++) {
		b[28 + i] = myip[i];
		b[38 + i] = tpa[i];
	}
	xmit(42);
}

same(a, b, n)
register unsigned char *a, *b;
register int n;
{
	while (n-- > 0)
		if (*a++ != *b++)
			return (0);
	return (1);
}

/*
 * The next frame within t hundredths, or 0.  ARP requests for myip are
 * answered on the way.  *np: its length less the FCS.  landone frees it.
 */
char *
lanrx(t, np)
unsigned t;
int *np;
{
	register unsigned *d;
	register unsigned char *f;
	register int n;

	if (held)
		landone();
	tstart();
	for (;;) {
		d = wp(RDR + 8 * rxi);
		if (d[1] & OWN) {
			if (tnow() >= t)
				return (0);
			continue;
		}
		n = (d[3] & 0x0fff) - 4;
		f = (unsigned char *)&lan[lo + RBUF + BUFSZ * rxi];
		held = 1;
		if ((d[1] & (STP | ENP | ERR)) != (STP | ENP) || n < 14) {
			landone();
			continue;
		}
		if (f[12] == 0x08 && f[13] == 0x06 && n >= 42 && f[21] == 1
		    && myip[0] | myip[1] | myip[2] | myip[3]
		    && same(f + 38, myip, 4)) {
			arp(2, f + 22, f + 28);
			landone();
			continue;
		}
		*np = n;
		return ((char *)f);
	}
}

landone()
{
	if (held) {
		held = 0;
		give(rxi);
		rxi = (rxi + 1) & (NRX - 1);
	}
}
