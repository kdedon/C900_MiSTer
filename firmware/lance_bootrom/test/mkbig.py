#!/usr/bin/env python3
"""ndbig.bin for the card ROM test: a pattern over two segments, not a
whole number of blocks.  Prints its block count and byte sum as ndhook
does.

    mkbig.py out.bin
"""
import sys

N = 68 * 1024 + 100


def main():
    d = bytes((i * 7 + (i >> 9)) & 0xff for i in range(N))
    open(sys.argv[1], 'wb').write(d)
    print('big %04x blocks sum %04x' % ((N + 511) // 512, sum(d) & 0xffff))


main()
