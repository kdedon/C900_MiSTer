/*
 * The boot file for the card ROM test: an l.out the hook loads through
 * nd.read and jumps to.  Prints NDPROG OK from its data segment.
 */
#define ROMABI	0x029eL
#define HSVC(n)	((long (*)())(ROMABI + 16 + 8 * (n)))

static char	msg[] = "NDPROG OK\n";

pmain()
{
	(*HSVC(2))(msg);
	for (;;)
		;
}
