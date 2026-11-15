#!/usr/bin/env python3
"""Writes a tiny COHERENT Z8001 l.out for netboot.sh: it prints a line on
SCC U74 B, then spins.  Per character, as as-z8001 assembles it:

    1:  inb   rl1, 0x0101     / RR0
        bitb  rl1, $2         / Tx Buffer Empty
        jr    z, 1b
        ldb   rl0, $c
        outb  0x0111, rl0
    2:  jr    2b

The header is nld -i's (magic 0407, LF_SEP|LF_32, machine 4, text at
0x30, entry segment 3 offset 0); longs are stored high word first.

    mknethello.py out.l [text]      (default "NETBOOT OK")
"""
import struct
import sys


def lng(v):
    return struct.pack('<HH', v >> 16, v & 0xffff)


def main():
    out = sys.argv[1]
    text = (sys.argv[2] if len(sys.argv) > 2 else 'NETBOOT OK') + '\r\n'
    code = b''.join(bytes.fromhex('3a940101a692e6fcc8') + bytes([ord(c)]) + bytes.fromhex('3a860111')
                    for c in text) + bytes.fromhex('e8ff')
    sizes = [len(code)] + [0] * 8
    hdr = struct.pack('<HHHH', 0o407, 0o22, 4, 0x30) + b''.join(lng(s) for s in sizes) + lng(0x03000000)
    open(out, 'wb').write(hdr + code)


main()
