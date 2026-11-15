#!/usr/bin/env python3
"""LANCE loopback test as a boot floppy program, made from lance.s.

    python3 mklance.py > lance_fd.s

The ROM loads it from (fd,1)coherent into segment 0x30 (build the image
with C900 bench/sysclk/mkboot.py).  It maps logical segment 0x20 to
physical 0x100000 and runs lance.s there: the card's addresses are
physical, so the init block, rings and buffers move from 08xxxx to 10xxxx
(RMD1 0310 instead of 0308).  Its own PSA there takes the ROM's trap
entries and vector 88; any other VI is counted.  Then it puts the ROM's
PSA back and prints
through the ROM's console (putchar at 00:0FC2), one line per run:

    E 06F2 0310 0024 0000 FF88 PASS      external loopback
    I 06F2 0310 0024 0000 FF88 PASS      internal loopback

(CSR0 bits seen, RMD1, RMD3, wrong data words, identifier.)
"""
import os
import re

SEG = 0x20                      # logical segment of the work area
PHYS = 0x10                     # its physical address bits 23:16
EXPECT = [0x06F2, 0x0300 | PHYS, 0x0024, 0x0000, 0xFF88]


def sub(s, old, new, count):
    assert s.count(old) == count, (old, s.count(old))
    return s.replace(old, new)


def chars(text):
    out = []
    for c in text:
        out += ["\tldb\trl0, $0x%02x" % ord(c), "\tcalr\tputc"]
    return "\n".join(out) + "\n"


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    s = open(os.path.join(here, "lance.s")).read()
    # prologue: the ROM has set the MMU, refresh and the stack
    i, j = s.index("start:\n"), s.index("/ PSA at 08:0000")
    s = s[:i] + "\t.globl\tstart\nstart:\n" + "\n".join([
        "\tld\tr0, $0xc000",
        "\tldctl\tFCW, r0",
        "/ segment 0x%02x -> physical 0x%02x0000" % (SEG, PHYS),
        "\tld\tr1, $0xFF00",
        "\tldb\trl0, $0x%02x" % SEG,
        "\tsoutb\tMMU+0x0100, rl0",
        "\tld\tr0, $0x%02x00" % PHYS,
        "\tcalr\tdesc",
        ""]) + s[j:]
    # our PSA at SEG|0000: the ROM's trap entries, every VI vector to
    # stray, vector 88 to vi; the ROM's PSA pointer kept in rr12
    i, j = s.index("/ PSA at 08:0000"), s.index("/ the frame at")
    s = s[:i] + "\n".join([
        "/ PSA at %02x:0000: the ROM's traps, VI vectors to stray, 88 to vi" % SEG,
        "\tldctl\tr12, PSAPSEG",
        "\tand\tr12, $0x7F00",
        "\tldctl\tr13, PSAPOFF",
        "\tldl\trr2, rr12",
        "\tldl\trr4, $0x%02x000000" % SEG,
        "\tld\tr0, $0x38",
        "\tldirb\t@rr4, @rr2, r0",
        "\tld\t@rr4, $0",
        "\tinc\tr5, $2",
        "\tld\t@rr4, $0xC000",
        "\tinc\tr5, $2",
        "\tldar\tr0, stray",
        "\tld\tr6, $128",
        "1:\tldl\t@rr4, rr0",
        "\tinc\tr5, $4",
        "\tdjnz\tr6, 1b",
        "\tldl\trr4, $0x%02x00014C" % SEG,
        "\tldar\tr0, vi",
        "\tldl\t@rr4, rr0",
        "\tld\tr0, $0x%02x00" % SEG,
        "\tldctl\tPSAPSEG, r0",
        "\tclr\tr0",
        "\tldctl\tPSAPOFF, r0",
        ""]) + s[j:]
    s = re.sub(r"\$0x0800([0-9A-F]{4})\b", r"$0x%02x00\1" % SEG, s)
    assert "0x0800" not in s.replace("$0x0800\n", ""), "08 address left"
    # physical address bits 23:16: CSR2, the ring pointers, the descriptors
    s = sub(s, "\tld\t@rr2, $0x0008\n", "\tld\t@rr2, $0x%04x\n" % PHYS, 2)
    s = sub(s, "\tld\tr0, $0x0008\n", "\tld\tr0, $0x%04x\n" % PHYS, 1)
    s = sub(s, "$0x8008\n", "$0x%04x\n" % (0x8000 | PHYS), 1)
    s = sub(s, "$0x8308\n", "$0x%04x\n" % (0x8300 | PHYS), 1)
    # results: print instead of parking
    tail = ["/ the ROM's PSA back; expected words at 0F40; print both runs",
             "\tldctl\tPSAPSEG, r12",
             "\tldctl\tPSAPOFF, r13",
             "\tldl\trr2, $0x%02x000F40" % SEG]
    for _ in range(2):
        for e in EXPECT:
            tail += ["\tld\t@rr2, $0x%04x" % e, "\tinc\tr3, $2"]
    tail += ["\tldl\trr8, $0x%02x000F00" % SEG,
             "\tldl\trr10, $0x%02x000F40" % SEG,
             "\tldb\trl0, $0x45",
             "\tcalr\tline",
             "\tldb\trl0, $0x49",
             "\tcalr\tline",
             "park:",
             "\tjr\tpark"]
    s = sub(s, "park:\n\tjr\tpark\n", "\n".join(tail) + "\n", 1)
    s += """/ line: rl0, then five words at rr8 checked against rr10, PASS or FAIL
line:
\tcalr\tputc
\tld\tr7, $0
\tld\tr5, $5
1:\tldb\trl0, $0x20
\tcalr\tputc
\tld\tr1, @rr8
\tcp\tr1, @rr10
\tjr\tz, 2f
\tinc\tr7, $1
2:\tcalr\thex4
\tinc\tr9, $2
\tinc\tr11, $2
\tdjnz\tr5, 1b
\ttest\tr7
\tjr\tnz, 3f
""" + chars(" PASS") + "\tjr\t4f\n3:\n" + chars(" FAIL") + "4:\n" + chars("\r\n") + """\tret
/ stray: any other vectored interrupt; identifier to 0F90, count at 0F92
stray:
\tpushl\t@rr14, rr2
\tpushl\t@rr14, rr0
\tldl\trr2, rr14
\tinc\tr3, $8
\tld\tr0, @rr2
\tldl\trr2, $0x%02x000F90
\tld\t@rr2, r0
\tinc\tr3, $2
\tinc\t@rr2, $1
\tpopl\trr0, @rr14
\tpopl\trr2, @rr14
\tiret
/ hex4: r1 as four hex digits
hex4:
\tld\tr6, $4
1:\trl\tr1, $2
\trl\tr1, $2
\tldb\trl0, rl1
\tandb\trl0, $0x0f
\tcpb\trl0, $9
\tjr\tule, 2f
\taddb\trl0, $7
2:\taddb\trl0, $0x30
\tcalr\tputc
\tdjnz\tr6, 1b
\tret
/ putc: rl0 through the ROM's putchar (00:0FC2), registers kept
putc:
\tsub\tr15, $32
\tldm\t(rr14), r0, $16
\tclrb\trh0
\tpush\t(rr14), r0
\tcall\t0|0x0fc2
\tinc\tr15, $2
\tldm\tr0, (rr14), $16
\tadd\tr15, $32
\tret
"""
    s = s.replace("/ LANCE card check for tb_core (+lance), run from the reset PC 0x0038 in\n"
                  "/ place of the BIOS.",
                  "/ lance_fd.s -- generated by mklance.py from lance.s; edit those, not this.\n"
                  "/ LANCE card check from a boot floppy.")
    s = s.replace("$0x%02x000F90", "$0x%02x000F90" % SEG)
    print(s, end="")


if __name__ == "__main__":
    main()
