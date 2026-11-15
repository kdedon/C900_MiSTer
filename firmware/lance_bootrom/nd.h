/*
 * LANCE card boot ROM: the network boot device "nd".
 *
 * Logical segments while the ROM is in use:
 *   TSEG  text, read-only, mapped by the BIOS onto the copy
 *   DSEG  data, bss and stack, mapped by init onto the copy past the text
 */
#define TSEG	0x28
#define DSEG	0x29

#define DP(seg, off)	((char *)((long)(seg) << 24 | (unsigned)(off)))

/* C9JT services */
#define JT_PUTCHAR	0
#define JT_PUTS		2
extern char	*jt;

/* card ports */
#define RDP	0x0700
#define RAP	0x0702
#define PROM	0x0710
#define ROMA	0x0718
#define ROMD	0x071a

/* IP configuration block, window words 3FE0-3FFF */
#define CFGW	0x3fe0
#define CF_STATIC	0x01
#define CF_BOOTP	0x02
#define CF_VALID	0x80

/* C9RC: the BIOS's romconf, by byte offset */
#define RC_MAGIC	16
#define RC_LENGTH	22
#define RC_RSVDSEG	114

struct ndev {
	char	nd_magic[4];	/* "C9ND" */
	unsigned nd_version;	/* 1 */
	char	nd_name[2];	/* "nd" */
	int	nd_uoff;	/* unit offset */
	char	*(*nd_open)();	/* open(arg): start the file's read; 0 or an error */
	int	(*nd_read)();	/* read(unit, blk, buf): 1 ok, 0 past the end or failed */
	char	*(*nd_info)();	/* one line for the monitor */
};

/* network state, net.c */
extern unsigned char	mymac[6], myip[4], mask[4], gw[4], srv[4];
extern char		bootfile[128];

/* the TFTP read, net.c: block tblk (from 1) in tdata, tlen bytes */
extern char		tname[128], tdata[512];
extern long		tblk;
extern int		tlen, tdone;
extern char		*tfopen(), *tfnext();

extern long	physd();
extern char	*lanrx();
extern unsigned	tnow();
