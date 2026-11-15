#!/usr/bin/env python3
"""Z8070 APU test program, for tb_core and for a boot floppy.

    python3 mkfpu.py tb    > fpu.s     reset entry at 0x0038 in place of the BIOS,
                                       results as SCC U74 channel B data writes
    python3 mkfpu.py flop  > fpu.s     a program the ROM loads from (fd,1)coherent
                                       into segment 0x30; results through the
                                       ROM's console (putchar at 00:0FC2)
    python3 mkfpu.py patch AS OUT.patch
                                       assemble the tb form with as-z8001 and write
                                       the tb_core ROM patch ("<offset> <byte>")

The program reads SC through FLDCTL with EPA set.  All ones (an undriven
bus) means no APU: it clears EPA, runs an extended instruction and expects
the Extended Instruction trap, printing "NE".  Otherwise it prints "Y" and
one letter per check, lower case when the check fails:
  A  FLD 1.5, FLD 2.5, FADD, FST double: 4.0
  M  FMUL by 2.5: 10.0
  D  FDIV by 2.5: 4.0
  Q  FLD 1.0, FLD 3.0, FDIV, FST double: 1/3 = 3FD5555555555555
  S  FST single of 4.0: 40800000
  T  FDIV 1.0 by 0.0 with the DZ trap enabled: /INT, VI vector 10H
The last character is P when every check passed, else F.
Expected: "YAMDQSTP" with the APU, "NEP" without.

The assembler has no EPU mnemonics; the words come from the Z8070
template frame (EPU <- memory 4F04, memory <- EPU 4F0C, internal 8E04,
EPU <- CPU 8F08, CPU <- EPU 8F00; ID 0) and the operation field
{w2[15:14], w2[7:4]}: FLD 20, FADD 18, FDIV 1A, FMUL 1B, FLDCTL 30.
"""
import struct
import subprocess
import sys

TB_BASE = 0x38


def w(*words):
    return "\t.word\t" + ", ".join("0x%04x" % x for x in words)


def addr(seg, off):
    return [0x8000 | seg << 8, off]


def fld(seg, f, off, n=4):          # EPU <- memory, n words
    return w(0x4F04, 0x8000 | f << 8 | (n - 1), *addr(seg, off))


def fst(seg, f, off, n=4):          # memory <- EPU
    return w(0x4F0C, 0x8000 | f << 8 | (n - 1), *addr(seg, off))


def internal(code, fd, fs):
    return w(0x8E04 | fd << 4, (code >> 4) << 14 | fs << 8 | (code & 0xF) << 4)


def fadd(fd, fs): return internal(0x18, fd, fs)
def fmul(fd, fs): return internal(0x1B, fd, fs)
def fdiv(fd, fs): return internal(0x1A, fd, fs)


def ctl_from_rr0(reg):              # FLDCTL reg, RR0
    return w(0x8F08 | reg << 4, 0xC001)


def ctl_from_r0(reg):               # FLDCTL reg, R0 (USER is one word)
    return w(0x8F08 | reg << 4, 0xC000)


def ctl_to_rr0(reg):                # FLDCTL RR0, reg
    return w(0x8F00 | reg << 4, 0xC001)


SC, USER = 0, 5

# data segment offsets
CONST, RES, FLAGS, STACK = 0x400, 0x500, 0x600, 0x1000
F_EPA, F_VI, F_STRAY = FLAGS, FLAGS + 2, FLAGS + 4
CONSTS = [0x3FF8, 0, 0, 0,          # 1.5
          0x4004, 0, 0, 0,          # 2.5
          0x3FF0, 0, 0, 0,          # 1.0
          0x4008, 0, 0, 0,          # 3.0
          0, 0, 0, 0]               # 0.0
C15, C25, C10, C30, C00 = (CONST + 8 * i for i in range(5))


def body(D):
    """Everything after the prologue: D is the data segment."""
    seg = "0x%02x" % D
    L = []
    a = L.append
    # program status area at D|0: EPA trap, every VI vector to stray, 10H to vi
    a("\tld\tr0, $0x%02x00" % D)
    a("\tldctl\tPSAPSEG, r0")
    a("\tclr\tr0")
    a("\tldctl\tPSAPOFF, r0")
    a("\tld\tr0, $0xc000")
    a("\tld\t%s|0x0a, r0" % seg)
    a("\tld\t%s|0x3a, r0" % seg)
    a("\tldar\trr2, epa")
    a("\tldl\t%s|0x0c, rr2" % seg)
    a("\tldar\trr2, stray")
    a("\tld\tr0, $128")
    a("\tldl\trr12, $0x%02x00003c" % D)
    a("1:\tldl\t(rr12), rr2")
    a("\tinc\tr13, $4")
    a("\tdjnz\tr0, 1b")
    a("\tldar\trr2, vi")
    a("\tldl\t%s|0x5c, rr2" % seg)
    a("\tclr\t%s|0x%x" % (seg, F_EPA))
    a("\tclr\t%s|0x%x" % (seg, F_VI))
    a("\tclr\t%s|0x%x" % (seg, F_STRAY))
    # constants to RAM
    a("\tldar\trr2, consts")
    a("\tldl\trr4, $0x%02x00%04x" % (D, CONST))
    a("\tld\tr0, $%d" % len(CONSTS))
    a("\tldir\t(rr4), (rr2), r0")
    a("\tclr\tr8")                                  # failures
    # is there an APU?  SC through FLDCTL with EPA set
    a("\tld\tr0, $0xe000")
    a("\tldctl\tFCW, r0")
    a("\tld\tr0, $0x1234")
    a("\tld\tr1, $0x5678")
    a(ctl_to_rr0(SC))
    a("\tand\tr0, r1")
    a("\tcp\tr0, $0xffff")
    a("\tjr\tne, apu")
    # no APU: an extended instruction with EPA clear traps
    a("\tldb\trl0, $'N")
    a("\tcalr\tputc")
    a("\tld\tr0, $0xc000")
    a("\tldctl\tFCW, r0")
    a("\tldar\trr4, 1f")
    a("\tldl\trr6, rr14")
    a(fld(D, 1, C15))
    a("1:\tldb\trl0, $'E")
    a("\tld\tr1, %s|0x%x" % (seg, F_EPA))
    a("\tcalr\tmark")
    a("\tjr\tdone")
    # with the APU
    a("apu:")
    a("\tldb\trl0, $'Y")
    a("\tcalr\tputc")
    a(fld(D, 1, C15))
    a(fld(D, 2, C25))
    a(fadd(1, 2))
    a(fst(D, 1, RES + 0x00))
    a("\tldb\trl0, $'A")
    a("\tld\tr6, $0x%04x" % (RES + 0x00))
    a("\tcalr\tcheck")
    a(fmul(1, 2))
    a(fst(D, 1, RES + 0x08))
    a("\tldb\trl0, $'M")
    a("\tld\tr6, $0x%04x" % (RES + 0x08))
    a("\tcalr\tcheck")
    a(fdiv(1, 2))
    a(fst(D, 1, RES + 0x10))
    a("\tldb\trl0, $'D")
    a("\tld\tr6, $0x%04x" % (RES + 0x10))
    a("\tcalr\tcheck")
    a(fld(D, 3, C10))
    a(fld(D, 4, C30))
    a(fdiv(3, 4))
    a(fst(D, 3, RES + 0x18))
    a("\tldb\trl0, $'Q")
    a("\tld\tr6, $0x%04x" % (RES + 0x18))
    a("\tcalr\tcheck")
    a(fst(D, 1, RES + 0x20, n=2))
    a("\tldb\trl0, $'S")
    a("\tld\tr6, $0x%04x" % (RES + 0x20))
    a("\tcalr\tcheck2")
    # trap: USER DZ enable, SC MIE, VI acknowledge, vector 10H
    a("\tld\tr0, $0x0800")
    a(ctl_from_r0(USER))
    a("\tld\tr0, $0x0003")
    a("\tld\tr1, $0x8010")
    a(ctl_from_rr0(SC))
    a("\tld\tr0, $0xf000")
    a("\tldctl\tFCW, r0")
    a(fld(D, 5, C10))
    a(fld(D, 6, C00))
    a(fdiv(5, 6))
    a("\tld\tr9, $20000")
    a("1:\ttest\t%s|0x%x" % (seg, F_VI))
    a("\tjr\tnz, 2f")
    a("\tdjnz\tr9, 1b")
    a("2:\tld\tr0, $0xe000")
    a("\tldctl\tFCW, r0")
    a("\tldb\trl0, $'T")
    a("\tld\tr1, %s|0x%x" % (seg, F_VI))
    a("\tcalr\tmark")
    a("done:")
    a("\tldb\trl0, $0x50")
    a("\ttest\tr8")
    a("\tjr\tz, 1f")
    a("\tldb\trl0, $'F")
    a("1:\tcalr\tputc")
    a("park:")
    a("\tjr\tpark")
    # check: the double at D|r6 against the next 4 table words; rl0 = letter
    for name, n in (("check", 4), ("check2", 2)):
        a(name + ":")
        a("\tld\tr7, r6")
        a("\tsub\tr7, $0x%04x" % RES)
        a("\tldar\trr2, expect")
        a("\tadd\tr3, r7")
        a("\tld\tr5, r6")
        a("\tld\tr4, $0x%02x00" % D)
        a("\tld\tr9, $%d" % n)
        a("\tclr\tr1")
        a("1:\tld\tr7, (rr4)")
        a("\tcp\tr7, (rr2)")
        a("\tjr\teq, 2f")
        a("\tinc\tr1, $1")
        a("2:\tinc\tr5, $2")
        a("\tinc\tr3, $2")
        a("\tdjnz\tr9, 1b")
        a("\ttest\tr1")
        a("\tjr\tz, 3f")
        a("\tinc\tr8, $1")
        a("\taddb\trl0, $0x20")
        a("3:\tcalr\tputc")
        a("\tret")
    # mark: rl0 = letter, r1 = flag (nonzero = pass)
    a("mark:")
    a("\ttest\tr1")
    a("\tjr\tnz, 1f")
    a("\tinc\tr8, $1")
    a("\taddb\trl0, $0x20")
    a("1:\tcalr\tputc")
    a("\tret")
    # Extended Instruction trap: flag, drop the frame, go on at rr4.  Back to
    # the caller's stack: the ROM's putchar reads its argument at 3F|r15.
    a("epa:")
    a("\tld\tr0, $1")
    a("\tld\t%s|0x%x, r0" % (seg, F_EPA))
    a("\tldl\trr14, rr6")
    a("\tjp\t(rr4)")
    # VI 10H: the APU's trap
    a("vi:")
    a("\tpush\t(rr14), r0")
    a("\tld\tr0, $1")
    a("\tld\t%s|0x%x, r0" % (seg, F_VI))
    a("\tpop\tr0, (rr14)")
    a("\tiret")
    # any other VI: count it and return with VI disabled
    a("stray:")
    a("\tpushl\t(rr14), rr2")
    a("\tinc\t%s|0x%x, $1" % (seg, F_STRAY))
    a("\tldl\trr2, rr14")
    a("\tinc\tr3, $6")
    a("\tres\t(rr2), $12")
    a("\tpopl\trr2, (rr14)")
    a("\tiret")
    a("\t.even")
    a("consts:")
    for i in range(0, len(CONSTS), 4):
        a(w(*CONSTS[i:i + 4]))
    a("expect:")
    a(w(0x4010, 0, 0, 0))                           # A 4.0
    a(w(0x4024, 0, 0, 0))                           # M 10.0
    a(w(0x4010, 0, 0, 0))                           # D 4.0
    a(w(0x3FD5, 0x5555, 0x5555, 0x5555))            # Q 1/3
    a(w(0x4080, 0x0000))                            # S 4.0 single
    return L


def tb():
    D = 0x08
    MMU = 0x00FC
    L = ["/ fpu.s -- generated by mkfpu.py tb; edit that, not this.",
         "/ Z8070 APU test for tb_core, from the reset PC 0x0038.",
         "start:",
         "\tldl\trr14, $0x%02x00%04x" % (D, STACK),
         "\tld\tr0, $0x9e00",
         "\tldctl\tREFRESH, r0",
         "/ descriptors: 00 -> 0000, 08 -> 0800",
         "\tld\tr1, $0xFF00",
         "\tldb\trl0, $0x00",
         "\tsoutb\t0x%04x, rl0" % (MMU + 0x100),
         "\tld\tr0, $0x0000",
         "\tcalr\tdesc",
         "\tldb\trl0, $0x08",
         "\tsoutb\t0x%04x, rl0" % (MMU + 0x100),
         "\tld\tr0, $0x0800",
         "\tcalr\tdesc",
         "\tldb\trl0, $0xC0",
         "\tsoutb\t0x%04x, rl0" % MMU]
    L += body(D)
    L += ["desc:"] + ["\tsoutb\t0x%04x, %s" % (MMU + 0xF00, r) for r in ("rh0", "rl0", "rh1", "rl1")]
    L += ["\tret",
          "/ putc: rl0 to SCC U74 channel B's data register",
          "putc:",
          "\toutb\t0x0111, rl0",
          "\tret"]
    return L


def flop():
    D = 0x31
    L = ["/ fpu.s -- generated by mkfpu.py flop; edit that, not this.",
         "/ Z8070 APU test loaded by the boot ROM into segment 0x30, data in 0x31.",
         "\t.globl\tstart",
         "start:",
         "\tld\tr0, $0xc000",
         "\tldctl\tFCW, r0"]
    L += body(D)
    L += ["/ putc: rl0 through the ROM's putchar (00:0FC2), registers kept",
          "putc:",
          "\tsub\tr15, $32",
          "\tldm\t(rr14), r0, $16",
          "\tclrb\trh0",
          "\tpush\t(rr14), r0",
          "\tcall\t0|0x0fc2",
          "\tinc\tr15, $2",
          "\tldm\tr0, (rr14), $16",
          "\tadd\tr15, $32",
          "\tret"]
    return L


def patch(asm, out):
    src = out + ".s"
    obj = out + ".o"
    open(src, "w").write("\n".join(tb()) + "\n")
    r = subprocess.run([asm, "-o", obj, src], capture_output=True, text=True)
    if r.returncode != 0 or r.stdout.strip() or r.stderr.strip():
        sys.exit("as-z8001: " + r.stdout + r.stderr)
    d = open(obj, "rb").read()
    magic, flag, mach, tbase = struct.unpack_from("<4H", d, 0)
    h, lo = struct.unpack_from("<HH", d, 8)
    text = d[tbase:tbase + (h << 16 | lo)]
    with open(out, "w") as f:
        for i in range(0, len(text), 2):
            a = TB_BASE + i
            f.write("%05x %02x\n" % (a // 2, text[i]))          # U17: high byte
            f.write("%05x %02x\n" % (0x4000 + a // 2, text[i + 1]))


if __name__ == "__main__":
    if sys.argv[1] == "tb":
        print("\n".join(tb()))
    elif sys.argv[1] == "flop":
        print("\n".join(flop()))
    elif sys.argv[1] == "patch":
        patch(sys.argv[2], sys.argv[3])
