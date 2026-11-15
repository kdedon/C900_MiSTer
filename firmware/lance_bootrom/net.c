/*
 * IP, UDP, ARP, BOOTP and TFTP over the LANCE, polled.
 */
#include "nd.h"

#define MYPORT	1069
#define TFTPS	69
#define BOOTPS	67
#define BOOTPC	68

extern char	*tbuf();

unsigned char	myip[4], mask[4], gw[4], srv[4];
char		bootfile[128];
static unsigned char	hop[4], hopmac[6];
static unsigned char	any[4] = { 255, 255, 255, 255 };
static unsigned char	zero[4];
static unsigned char	bcmac[6] = { 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };
static unsigned long	xid;

unsigned
w16(p)
register unsigned char *p;
{
	return (p[0] << 8 | p[1]);
}

put16(p, v)
register unsigned char *p;
unsigned v;
{
	p[0] = v >> 8;
	p[1] = v;
}

static unsigned
cksum(p, n)
register unsigned char *p;
register int n;
{
	long sum;

	for (sum = 0; n > 1; n -= 2, p += 2)
		sum += w16(p);
	if (n)
		sum += (unsigned)*p << 8;
	while (sum >> 16)
		sum = (sum & 0xffffL) + (sum >> 16);
	return (~(unsigned)sum & 0xffff);
}

static
cpy(d, s, n)
register unsigned char *d, *s;
register int n;
{
	while (n-- > 0)
		*d++ = *s++;
}

static
eq4(a, b)
register unsigned char *a, *b;
{
	return (a[0] == b[0] && a[1] == b[1] && a[2] == b[2] && a[3] == b[3]);
}

/* UDP payload area of the frame being built */
unsigned char *
upay()
{
	return ((unsigned char *)tbuf() + 42);
}

/* Send the n-byte UDP payload at upay() from sport to dst:dport. */
udpsend(dmac, dst, sport, dport, n)
unsigned char *dmac, *dst;
unsigned sport, dport;
int n;
{
	register unsigned char *ip;

	ether(dmac, 0x0800);
	ip = (unsigned char *)tbuf() + 14;
	ip[0] = 0x45;
	ip[1] = 0;
	put16(ip + 2, 28 + n);
	put16(ip + 4, 0);
	put16(ip + 6, 0);
	ip[8] = 64;
	ip[9] = 17;
	put16(ip + 10, 0);
	cpy(ip + 12, myip, 4);
	cpy(ip + 16, dst, 4);
	put16(ip + 10, cksum(ip, 20));
	put16(ip + 20, sport);
	put16(ip + 22, dport);
	put16(ip + 24, 8 + n);
	put16(ip + 26, 0);
	xmit(42 + n);
}

/*
 * The next UDP datagram to port within t hundredths: its payload, or 0.
 * *np: payload length; *src: the sender's IP header (address at +12,
 * port at +20).  The frame stays held until the next lanrx.
 */
unsigned char *
udprx(port, t, np, src)
unsigned port, t;
int *np;
unsigned char **src;
{
	register unsigned char *f, *ip;
	register int len;
	int n;

	for (;;) {
		if ((f = (unsigned char *)lanrx(t, &n)) == 0)
			return (0);
		if (f[12] == 0x08 && f[13] == 0x06 && n >= 42 && f[21] == 2
		    && eq4(f + 28, hop)) {
			cpy(hopmac, f + 22, 6);
			hop[0] = hop[1] = hop[2] = hop[3] = 0;
			if (port == 0)
				return (0);
			continue;
		}
		if (f[12] != 0x08 || f[13] != 0x00 || n < 14 + 28)
			continue;
		ip = f + 14;
		len = w16(ip + 2);
		if (ip[0] != 0x45 || ip[9] != 17 || len < 28 || 14 + len > n
		    || cksum(ip, 20) != 0 || w16(ip + 22) != port)
			continue;
		if (!eq4(ip + 16, myip) && !eq4(ip + 16, any)
		    && !eq4(myip, zero))
			continue;
		*np = len - 28;
		*src = ip;
		return (ip + 28);
	}
}

/* Next hop for dst. */
static unsigned char *
route(dst)
register unsigned char *dst;
{
	register int i;

	for (i = 0; i < 4; i++)
		if ((dst[i] & mask[i]) != (myip[i] & mask[i]))
			return (gw[0] | gw[1] | gw[2] | gw[3] ? gw : dst);
	return (dst);
}

/* The Ethernet address of dst's next hop.  0 if it does not answer. */
resolve(dst)
unsigned char *dst;
{
	register int tries;
	unsigned char *p;
	int n;

	cpy(hop, route(dst), 4);
	for (tries = 0; tries < 4; tries++) {
		arp(1, bcmac, hop);
		udprx(0, 100, &n, &p);
		if ((hop[0] | hop[1] | hop[2] | hop[3]) == 0)
			return (1);
	}
	return (0);
}

/*
 * BOOTP: IP, server, file, and from the vendor area the mask and the
 * gateway.  0 or an error.
 */
char *
bootp()
{
	register unsigned char *b;
	register int i, tries;
	unsigned char *r, *ip;
	int n;

	xid = (long)mymac[2] << 24 | (long)mymac[3] << 16 | (unsigned)mymac[4] << 8 | mymac[5];
	cpy(myip, zero, 4);
	for (tries = 0; tries < 4; tries++) {
		b = upay();
		for (i = 0; i < 300; i++)
			b[i] = 0;
		b[0] = 1;
		b[1] = 1;
		b[2] = 6;
		b[4] = xid >> 24;
		b[5] = xid >> 16;
		b[6] = xid >> 8;
		b[7] = xid;
		put16(b + 8, tries);
		cpy(b + 28, mymac, 6);
		b[236] = 99;
		b[237] = 130;
		b[238] = 83;
		b[239] = 99;
		b[240] = 255;
		udpsend(bcmac, any, BOOTPC, BOOTPS, 300);
		puts("BOOTP ");
		while ((r = udprx(BOOTPC, 400, &n, &ip)) != 0) {
			if (n < 236 || r[0] != 2 || r[4] != (unsigned char)(xid >> 24)
			    || r[5] != (unsigned char)(xid >> 16) || r[6] != (unsigned char)(xid >> 8)
			    || r[7] != (unsigned char)xid || !same(r + 28, mymac, 6))
				continue;
			cpy(myip, r + 16, 4);
			cpy(srv, r + 20, 4);
			if (r[108])
				cpy(bootfile, r + 108, 128);
			bootfile[127] = 0;
			if (n >= 244 && r[236] == 99 && r[237] == 130 && r[238] == 83
			    && r[239] == 99)
				for (i = 240; i + 1 < n && r[i] != 255; ) {
					if (r[i] == 0) {
						i++;
						continue;
					}
					if (r[i] == 1 && r[i + 1] >= 4)
						cpy(mask, r + i + 2, 4);
					if (r[i] == 3 && r[i + 1] >= 4)
						cpy(gw, r + i + 2, 4);
					i += 2 + r[i + 1];
				}
			landone();
			return (0);
		}
	}
	return ("no BOOTP reply");
}

char		tname[128], tdata[512];
long		tblk;
int		tlen, tdone;
static unsigned	tport = MYPORT, tid;

static
rrq()
{
	register unsigned char *b;
	register int n;
	register char *f;
	char *m;

	b = upay();
	put16(b, 1);
	for (n = 2, f = tname; *f && n < 120; )
		b[n++] = *f++;
	b[n++] = 0;
	for (m = "octet"; *m; )
		b[n++] = *m++;
	b[n++] = 0;
	udpsend(hopmac, srv, tport, TFTPS, n);
}

/* DATA block tblk + 1 into tdata.  0 or an error. */
static char *
tget()
{
	register unsigned i, want;
	int n, tries;
	unsigned char *d, *ip;

	want = (unsigned)tblk + 1;
	for (tries = 0; tries < 5; ) {
		if ((d = udprx(tport, 300, &n, &ip)) == 0) {
			tries++;
			if (tblk == 0)
				rrq();
			else
				ack(tid, (unsigned)tblk);
			continue;
		}
		if (!eq4(ip + 12, srv) || n < 4 || tid && w16(ip + 20) != tid)
			continue;
		if (w16(d) == 5) {
			landone();
			return ("TFTP error from the server");
		}
		if (w16(d) != 3)
			continue;
		i = w16(d + 2);
		if (tblk && i == want - 1) {
			landone();
			ack(tid, i);
			continue;
		}
		if (i != want)
			continue;
		if (tid == 0)
			tid = w16(ip + 20);
		n -= 4;
		if (n > 512)
			n = 512;
		cpy(tdata, d + 4, n);
		landone();
		tblk++;
		tlen = n;
		if (n < 512) {
			ack(tid, want);
			tdone = 1;
		}
		if ((tblk & 31) == 0)
			putchar('.');
		return (0);
	}
	return ("no answer from the server");
}

/*
 * Read file from srv from its start, a new port each time so stray
 * blocks of an earlier read are dropped; 0 file: the last one again.
 * Ends with block 1 in tdata.  0 or an error.
 */
char *
tfopen(file)
register char *file;
{
	register int i;

	if (file) {
		for (i = 0; i < 127 && file[i]; i++)
			tname[i] = file[i];
		tname[i] = 0;
	}
	if (++tport < MYPORT)
		tport = MYPORT;
	tid = 0;
	tblk = 0;
	tdone = 0;
	rrq();
	return (tget());
}

/* ACK the block held, take the next. */
char *
tfnext()
{
	ack(tid, (unsigned)tblk);
	return (tget());
}

ack(tid, blk)
unsigned tid, blk;
{
	register unsigned char *b;

	b = upay();
	put16(b, 4);
	put16(b + 2, blk);
	udpsend(hopmac, srv, tport, tid, 4);
}
