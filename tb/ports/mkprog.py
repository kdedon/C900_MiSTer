#!/usr/bin/env python3
"""ROM patches (tb_core +patch) that run the port test programs at the
reset entry 0x0038: 'lp' is the Coherent lp driver's CIO sequence (md.s
lpclk + lpstart/lpintr, IP polled), 'tone' is U66 C/T 2 square wave on
PB0.  Usage: mkprog.py lp|tone > file.patch"""
import sys

RL0 = 8
code = []

def out(port, v):
    code.extend([0xC000 | RL0 << 8 | v, 0x3A06 | RL0 << 4, port])

def inb(port):
    code.extend([0x3A04 | RL0 << 4, port])

def wait_bit(port, b, set_):
    inb(port)
    cc = 0x6 if set_ else 0xE
    code.extend([0xA600 | RL0 << 4 | b, 0xE000 | cc << 8 | 0xFC])

def lp_init():
    for p, v in [(0x01, 1), (0x81, 1), (0x01, 0), (0x81, 0),
                 (0x59, 0), (0x55, 0), (0x57, 0), (0x1D, 0),
                 (0x0B, 0), (0x0D, 7), (0x0F, 0), (0x1F, 0x70), (0x03, 0x90),
                 (0xD1, 4), (0xD3, 0), (0xD5, 2), (0xD7, 2),
                 (0xD9, 2), (0xDB, 2), (0xDD, 0), (0xDF, 2),
                 (0x87, 0x70), (0x93, 0x20), (0x93, 0xC0),
                 (0x8B, 0), (0x8D, 0), (0x8F, 0), (0x9F, 0x08), (0xBD, 0), (0x83, 0x90)]:
        out(p, v)

def lp_char(c):
    wait_bit(0x1F, 0, False)
    out(0x1D, c); out(0x9F, 0x70); out(0x9F, 0x78)
    wait_bit(0x93, 5, True)
    out(0x93, 0x20)
    inb(0x9D)
    code.extend([0x0600 | RL0, 0xFDFD, 0x3A06 | RL0 << 4, 0x9D])

if sys.argv[1] == "lp":
    lp_init()
    for c in b"C900 lp\r\n":
        lp_char(c)
else:
    tc = 426
    for p, v in [(0x81, 1), (0x81, 0), (0xD7, 0xFE), (0xBB, 0xC2),
                 (0xB1, tc >> 8), (0xB3, tc & 0xFF), (0x83, 0xA0), (0x97, 0x06)]:
        out(p, v)
code.append(0xE8FF)  # JR T,$

base = 0x38 // 2
for i, w in enumerate(code):
    print("%05x %02x" % (base + i, w >> 8))
    print("%05x %02x" % (0x4000 + base + i, w & 0xFF))
