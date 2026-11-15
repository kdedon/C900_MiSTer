/*
 * The network boot device: open starts a TFTP read of the boot file,
 * read hands over its 512-byte blocks as they arrive.  The address comes
 * from the card's IP configuration, else from BOOTP.  The LANCE runs
 * only inside open and read.
 */
#include "nd.h"

/* CIO 1 counter/timer 2, as the BIOS's waits use it: 100 Hz at any CPU clock */
#define MCCR	0x0003
#define CT2CS	0x0017
#define CT2CH	0x0031
#define CT2CL	0x0033
#define CT2MS	0x003b
#define CT2E	0x20
#define IP	0x20

char		*jt;
static char	*rp;
static unsigned	dpage;
static int	netsrc;
static int	xopen;
static unsigned	ticks;
static unsigned char cfg[64];
static char	line[160];
extern unsigned	tpages;
extern char	edata[], end[];
extern char	*bootp();

char	*ndopen(), *ndinfo();
int	ndread();

struct ndev	ndev = {
	{ 'C', '9', 'N', 'D' }, 1, { 'n', 'd' }, 4, ndopen, ndread, ndinfo
};

putchar(c)
int c;
{
	jtcall(JT_PUTCHAR, c, 0);
}

puts(s)
char *s;
{
	jtcall(JT_PUTS, s);
}

long
physd(off)
unsigned off;
{
	return (((long)dpage << 8) + off);
}

tstart()
{
	outb(MCCR, inb(MCCR) & ~CT2E);
	outb(CT2MS, 0x80);
	outb(CT2CH, 30000 >> 8);
	outb(CT2CL, 30000 & 0xff);
	outb(CT2CS, IP);
	outb(MCCR, inb(MCCR) | CT2E);
	outb(CT2CS, 0x06);
	ticks = 0;
}

unsigned
tnow()
{
	if (inb(CT2CS) & IP) {
		outb(CT2CS, 0xa4);
		ticks++;
	}
	return (ticks);
}

/* Called by the BIOS once the image is mapped.  Returns the device. */
struct ndev *
cinit(r, j, work)
char *r, *j;
unsigned work;
{
	register char *p;

	for (p = edata; p < end; p++)
		*p = 0;
	rp = r;
	jt = j;
	dpage = work + tpages;
	lanmac();
	return (&ndev);
}

/* The configuration block from the window: 1 if valid. */
static
rdcfg()
{
	register int i;
	register unsigned w;

	outw(ROMA, CFGW);
	for (i = 0; i < 32; i++) {
		w = inw(ROMD);
		cfg[2 * i] = w >> 8;
		cfg[2 * i + 1] = w;
	}
	return (cfg[0] == 'C' && cfg[1] == '9' && cfg[2] == 'I' && cfg[3] == 'P'
	    && (cfg[7] & CF_VALID));
}

static
quad(sp, a)
char **sp;
unsigned char *a;
{
	register char *s;
	register int i, v;
	unsigned char q[4];

	s = *sp;
	for (i = 0; i < 4; i++) {
		for (v = 0; *s >= '0' && *s <= '9'; s++)
			v = v * 10 + *s - '0';
		q[i] = v;
		if (*s++ != (i < 3 ? '.' : ':'))
			return;
	}
	for (i = 0; i < 4; i++)
		a[i] = q[i];
	*sp = s;
}

static char *
dec(p, v)
register char *p;
unsigned v;
{
	char t[6];
	register int n;

	n = 0;
	do
		t[n++] = '0' + v % 10;
	while ((v /= 10) != 0);
	while (n > 0)
		*p++ = t[--n];
	return (p);
}

static char *
ipstr(p, a)
register char *p;
register unsigned char *a;
{
	register int i;

	for (i = 0; i < 4; i++) {
		p = dec(p, a[i]);
		*p++ = i < 3 ? '.' : ' ';
	}
	return (p);
}

static char *
str(p, s)
register char *p, *s;
{
	while (*s)
		*p++ = *s++;
	return (p);
}

/*
 * Start reading the boot file: arg "" is the configured file,
 * "[server:]file" another.  Returns 0 or an error.
 */
char *
copen(arg)
char *arg;
{
	register int i;
	char *e, *file;
	int st;

	xopen = 0;
	tname[0] = 0;
	for (i = 0; i < 4; i++)
		myip[i] = mask[i] = gw[i] = srv[i] = 0;
	bootfile[0] = 0;
	netsrc = 0;
	st = rdcfg();
	if (st && (cfg[7] & CF_STATIC)) {
		for (i = 0; i < 4; i++) {
			myip[i] = cfg[8 + i];
			mask[i] = cfg[12 + i];
			gw[i] = cfg[16 + i];
			srv[i] = cfg[20 + i];
		}
		for (i = 0; i < 40; i++)
			bootfile[i] = cfg[24 + i];
		bootfile[39] = 0;
		netsrc = 1;
	} else if (st && (cfg[7] & CF_BOOTP) == 0)
		return ("no IP configuration");
	if (!lanup())
		return ("LANCE does not start");
	e = 0;
	if (netsrc == 0) {
		if ((e = bootp()) == 0)
			netsrc = 2;
	}
	file = bootfile;
	if (e == 0 && *arg) {
		quad(&arg, srv);
		file = arg;
	}
	if (e == 0 && *file == 0)
		e = "no boot file";
	if (e == 0 && (srv[0] | srv[1] | srv[2] | srv[3]) == 0)
		e = "no server";
	if (e == 0 && !resolve(srv))
		e = "no ARP reply";
	if (e == 0) {
		puts("TFTP ");
		e = tfopen(file);
	}
	landown();
	if (e)
		return (e);
	xopen = 1;
	return (0);
}

/*
 * Block blk of the file to buf: 1, or 0 past its end or on a failure.
 * The next block ACKs the one held; an earlier one reads the file again.
 */
cread(unit, blk, buf)
int unit;
long blk;
register char *buf;
{
	register int i;
	char *e;

	if (!xopen || blk < 0)
		return (0);
	if (++blk != tblk) {
		if (blk > tblk && tdone)
			return (0);
		if (!lanup()) {
			puts("\nLANCE does not start\n");
			return (0);
		}
		e = 0;
		if (blk < tblk)
			e = tfopen((char *)0);
		while (e == 0 && tblk < blk && !tdone)
			e = tfnext();
		landown();
		if (e) {
			xopen = 0;
			puts("\n");
			puts(e);
			puts("\n");
			return (0);
		}
		if (blk != tblk)
			return (0);
	}
	if (tlen == 0)
		return (0);
	copy(buf, tdata, tlen);
	for (i = tlen; i < 512; i++)
		buf[i] = 0;
	return (1);
}

char *
cinfo()
{
	register char *p;
	register int i;
	static char hx[] = "0123456789abcdef";

	p = str(line, "nd ");
	for (i = 0; i < 6; i++) {
		*p++ = hx[mymac[i] >> 4];
		*p++ = hx[mymac[i] & 15];
		*p++ = i < 5 ? ':' : ' ';
	}
	if (netsrc) {
		p = ipstr(p, myip);
		p = str(p, "mask ");
		p = ipstr(p, mask);
		p = str(p, "gw ");
		p = ipstr(p, gw);
		p = str(p, "server ");
		p = ipstr(p, srv);
		for (i = 0; tname[i] && i < 40; i++)
			*p++ = tname[i];
	} else
		p = str(p, "not open");
	*p = 0;
	return (line);
}
