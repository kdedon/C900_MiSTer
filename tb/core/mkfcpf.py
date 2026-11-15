#!/usr/bin/env python3
"""FCPF check for tb_core: a ROM patch in place of the BIOS.

    python3 mkfcpf.py AS OUT.patch     (AS: as-z8001)

Loads F1 = 2.0, F2 = 0.75 from CPU registers, then FCPF F1,F2 (>),
FCPF F2,F1 (<) and FCPF F1,F1 (=), and writes the CPU flags byte
(LDCTLB RL0, FLAGS) after each to SCC U74 channel B's data register.
Expected 08 A8 40 (> D, < C S D, = Z; C Z S V D H in bits 7-2).
"""
import struct
import os
import subprocess
import sys
import tempfile

TB_BASE = 0x38


def w(*words):
    return "\t.word\t" + ", ".join("0x%04x" % x for x in words)


def fcpf(a, b):                 # FCW <- Fa : Fb
    return w(0x8E00 | a << 4, 0x4000 | b << 8 | 0x10)


L = ["start:",
     "\tld\tr0, $0xe000",
     "\tldctl\tFCW, r0",
     "\tclr\tr1",
     "\tclr\tr2",
     "\tclr\tr3",
     "\tld\tr0, $0x4000",
     w(0x8F18, 0x8003),         # FLD F1, RQ0
     "\tld\tr0, $0x3fe8",
     w(0x8F28, 0x8003)]         # FLD F2, RQ0
for a, b in ((1, 2), (2, 1), (1, 1)):
    L += [fcpf(a, b), "\tldctlb\trl0, FLAGS", "\toutb\t0x0111, rl0"]
L += ["1:\tjr\t1b"]

asm, out = sys.argv[1], sys.argv[2]
with tempfile.TemporaryDirectory() as t:
    src, obj = os.path.join(t, "fcpf.s"), os.path.join(t, "fcpf.o")
    open(src, "w").write("\n".join(L) + "\n")
    r = subprocess.run([asm, "-o", obj, src], capture_output=True, text=True)
    if r.returncode or r.stdout.strip() or r.stderr.strip():
        sys.exit("as-z8001: " + r.stdout + r.stderr)
    d = open(obj, "rb").read()
tbase = struct.unpack_from("<H", d, 6)[0]
h, lo = struct.unpack_from("<HH", d, 8)
text = d[tbase:tbase + (h << 16 | lo)]
with open(out, "w") as f:
    for i in range(0, len(text), 2):
        a = TB_BASE + i
        f.write("%05x %02x\n" % (a // 2, text[i]))
        f.write("%05x %02x\n" % (0x4000 + a // 2, text[i + 1]))
