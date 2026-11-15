#!/usr/bin/env python3
"""ROM patch (tb_core +patch) for the SCC/CIO CS1 check: at the reset entry
0x0038 the CPU builds a one-sector HD read command block at 08:0000, starts
the controller and polls its status byte, reading an SCC (scc), CIO U70
(cio) or LR card SCC U31 (lr0) / U36 (lr1) port in the same loop.  The 8716
then writes the sector to 08:0400, words with A7 = 0 and A7 = 1, some of
them right after the I/O cycle.
Usage: mkcs1.py scc|cio|lr0|lr1 > file.patch"""
import sys

port = {"scc": 0x0101, "cio": 0x0001, "lr0": 0x0301, "lr1": 0x0381}[sys.argv[1]]
RL0 = 8
code = []
# read, unit 0 block 2, one sector, status preset FF
for off, w in [(0x0, 0x0800), (0x2, 0x0002), (0x4, 0x0100), (0x6, 0x0804),
               (0x8, 0x0000), (0xA, 0x0000), (0xC, 0xFF00), (0xE, 0x0000)]:
    code.extend([0x4D05, 0x0800 | off, w])          # LD 08:off,#w
code.extend([0x2100, 0x0001, 0x3B06, 0x0500])       # LD R0,#1; OUT 0500H,R0
NIN = 16
code.extend([0x3A04 | RL0 << 4, port] * NIN)        # loop: INB RL0,port (x NIN)
code.extend([0x6000 | RL0, 0x080C,                  # LDB RL0,08:000C
             0x0A00 | RL0, 0xFFFF,                  # CPB RL0,#FF
             0xE600 | (-(2 * NIN + 5) & 0xFF)])     # JR EQ,loop
code.extend([0x2100, 0x0000, 0x3B06, 0x0500])       # LD R0,#0; OUT 0500H,R0
code.append(0xE8FF)                                 # JR T,$

base = 0x38 // 2
for i, w in enumerate(code):
    print("%05x %02x" % (base + i, w >> 8))
    print("%05x %02x" % (0x4000 + base + i, w & 0xFF))
