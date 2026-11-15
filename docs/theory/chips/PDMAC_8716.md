# MOS 8716 PDMAC (U79)

The "Z8000 Physical DMA Controller with FIFO". One 48-pin DIP on the
motherboard (symbol U790, Z8000 motherboard schematic sheet 18 "DMA
LOGIC"). It is the only DMA master in the machine and the only path
between Z8001 memory and the two disk controllers. Its sources are the
MOS drawing 315046 (reprinted in "CBM900 special chips", 16 sheets),
sheet 18, and the firmware that drives it.

Evidence legend: SOURCED = a document, schematic or firmware address;
INFERRED = a conclusion with its evidence; OPEN = unsettled, with what
would settle it. RTL: `rtl/motherboard/pdmac/*.sv`, `rtl/motherboard/pdmac/dma_addr.sv`
(the four TTL address chips).

## 1. What it is

SOURCED (315046 sheet 1-2): two functions. A command/status port on an
8-bit "B bus" (the board calls it OMAD or DMAD) driven by a disk
controller, and a Z-Bus master that moves 16-bit words between a 64-byte
FIFO and memory. The chip holds no address: the address lives in four
TTL chips next to it (section 4).

SOURCED (sheet 18; C900 Floppy Specification 2.16): one 8716 serves both
the floppy section (6508 + 8723, sheets 13-14) and the hard disk card
(8049 + WD2010, via CN9 pins 2-34). No hardware arbitrates between the
two cards; the host firmware runs one command at a time (section 7).

```
 Z8001/Z8010 ---- AD15:0, /MREQ, /DS, /WAIT, /BUSREQ, /BAI, /VI, IEI/IEO, /IACK
                      |
                 +----+----+      LD2 ---> U80 '374   DIR + word addr 22:16
                 |  8716   |      LD1 ---> U81 '374   word addr 15:8
                 | 64-byte |      LD0 ---> U82/U83 '193 word addr 7:0 (counts)
                 |  FIFO   |      CLKADR -> U83 count up
                 +----+----+      /DMAEN -> U84/U85 '244 put the address on AD
                      |
   BD7:0, /PCSS, /PCSD, _IREQ, _EST  ==== OMAD ====  8723 (U202 '245)  |  CN9 -> HDC card (U5 '245)
```

## 2. Pins as the C900 uses them

Pin numbers come from the sheet 18 symbol where legible; functions from
315046 sheets 3-4.

| Pin | Name | Dir | Use on the C900 | Evidence |
|-----|------|-----|-----------------|----------|
| AD15:0 | AD | I/O | Z-Bus word; carries the read word in, the write word and the interrupt vector out | sheet 3 |
| 47 | CLK | in | _CLK, 6 MHz (LS93 QA, the inverted CPU clock) | sheet 3 "inverted system clock"; DECISIONS D-CLK-3 |
| - | /MREQ, /DS | out | shared with the CPU's buffered _BMREQ/_BDS; driven only while /DMAEN is Low | sheet 18; `pdmac.sv` |
| - | /WAIT | in | sampled on the CLK rise in T2 and TW | sheet 3; OPEN O-18 whether the board wire reaches the pin |
| - | /BUSREQ | out, OD | to the Z8001 /BUSREQ | sheet 3 |
| - | /BAI | in | Z8001 /BUSACK | sheet 3 |
| - | /BAO | out | passes the grant on; nothing downstream on the C900 | sheet 3 |
| 3 | IO/6 (_IO_6) | in | I/O select: a write to 0x0500 with /DS Low sets _IREQ | sheet 3; BIOS 00:1134, Coherent `wd.c` WDIO = 0x0500 |
| 5 | /VI | out, OD | motherboard _VI bus, position after CIO U66 in the chain | sheet 18; DECISIONS D-BUS-4 |
| - | IEI, /IEO, /IACK | | Z-Bus interrupt daisy chain | sheet 3 |
| 17-24 | BD7:0 | I/O | OMAD byte bus: commands, LD data, FIFO bytes, status | sheet 4; sheet 18 |
| 31 | /PCSS | in | command strobe: the byte on BD is latched as a command | sheet 4 |
| 30 | /PCSD | in | data strobe: one byte in or out per strobe, meaning set by the last command | sheet 4 |
| 29 | _IREQ | out, OD | to the 6508 /IRQ (sheet 13) and CN9 22 -> HDC U2 -> 8049 T0 | sheet 18; HDC card sheet 2 |
| 8 | _EST | out | end-of-sector/transfer; CN9 28 -> HDC U2 -> 8049 T1 and U4 (WDMA-); unused by the floppy section | sheet 18; HDC card sheet 2; CCCP spec 4.1.28 |
| 32 | /RESET | in | board _MRESET; clears FIFO, DMA-in-progress, ERROR; does not touch the address chips | sheet 4 |
| - | CLKADR | out | count pulse to U83 after each word | sheet 4 |
| - | /DMAEN | out | enables U84/U85 (address onto AD), U80 Q7 onto BR/W, ST and /NOMMU during DMA | sheet 18; DECISIONS O-8 |
| - | LD0, LD1, LD2 | out | load strobes for the address chips (section 4) | sheet 4 |

SOURCED (sheet 18, HDC card sheet 3): the chip has no /CS and no /CREQ
pin; the WD2010's BDRQ is not connected. An earlier simulator model gave
it both; the RTL has neither.

OPEN O-17: the Design Review schematic draws pin 3 from U57 Y6 (0x0600)
while the BIOS and kernel write 0x0500 and boot on hardware. The core
decodes 0x0500. A meter on U79.3 against U57.9/U57.10 settles it.

## 3. The command port

SOURCED (sheet 7, "PCSS command table"): the controller puts a byte on
BD, pulses /PCSS, then moves data with /PCSD pulses. Each command is a
single-Low-bit code.

| PCSS byte | Name | Effect | Next /PCSD |
|-----------|------|--------|------------|
| 0xFF | Power_On | "issue after power-on reset"; no listed effect | - |
| 0x7F | Reset | clears FIFO and DMA state; "LD0 not allowed right after" | - |
| 0xFB | LD2 | LD2 Low | BD7 = DIR (1 = memory read, memory -> FIFO), BD6:0 = word address 22:16 |
| 0xFD | LD1 | LD1 Low | word address 15:8 |
| 0xFE | LD0 | LD0 Low; arms a 256-word block on the LD0 rise | word address 7:0 |
| 0xF7 | FIFO_MOVE | | one byte: push (DIR = write) or pop (DIR = read) per strobe |
| 0xEF | Rd_Status | | chip drives BD7 = DMADONE, BD6 = BYTERDY, BD5 = ERROR |
| 0x9F | IRQ_HIGH | releases _IREQ | - |
| 0xBF | VI_GND | asserts /VI | - |
| 0xDE/0xDF | Single_Step | one word instead of a block; BD0 don't care | word address 7:0, as LD0 |

Status bits (sheet 7): DMADONE Low while a word (single step) or a
256-word block is in flight, High when idle; BYTERDY High when the FIFO
holds a byte; ERROR Low after a pop from an empty FIFO.

Direction naming: "read" is the chip's view (it reads memory, host ->
disk); Coherent and the BIOS call that a disk write.

INFERRED, data edges (`pcss_unit.sv` header): bytes the chip drives go
out at the /PCSD assertion; bytes it takes (LD data, a pushed FIFO byte)
are taken at the release edge. Evidence: sheet 7 (DIR is BD7 at the LD2
rise and LD2 rises with /PCSD), sheet 10 and the Table I setup/hold
numbers (T6/T7, T10/T11). OPEN O-1: whether /PCSS latches on its fall or
rise (sheet 4 and sheet 7 disagree).

INFERRED (`pcss_unit.sv`): commands decode on the whole byte, not per
select line. Evidence: the 6508 sends PCSS 0x00 after every sector it
reads (e2e9 sends RAM $ef, which the RAM test leaves 0); a per-line
decode would be Reset + IRQ_HIGH + VI_GND at once and floppy reads
would not work. OPEN O-15/O-39: a bench 8716 with unlisted codes.

Timing the controllers rely on (sheet 16 Table I): /PCSS Low 80 ns min,
/PCSS to /PCSD 80 ns min, data setup 50 ns, the chip's BD valid 100 ns
max after /PCSD and held 30 ns past its release. The 6508 meets these
with one 0x4003/0x4005/0x4006 access per strobe; the HDC card's PAL U8
meets them from the 8049's WR-/RD- (see HDC_CARD.md).

## 4. The address chips (U80-U83) and the bus during DMA

SOURCED (sheet 18): the 23-bit word address and DIR live outside the chip.

| Ref | Part | Holds | Loaded by | Counted by |
|-----|------|-------|-----------|------------|
| U80 | 74LS374 | Q7 = DIR (-> BR/W), Q6:0 = word address 22:16 | LD2 rise | - |
| U81 | 74LS374 | word address 15:8 | LD1 rise | - |
| U83 | 74LS193 | word address 3:0 | LD0 Low (/LOAD) | CLKADR |
| U82 | 74LS193 | word address 7:4 | LD0 Low | U83 TC_UP |
| U84, U85 | 74LS244 | drive the address onto AD | /DMAEN | - |

Byte address = word address x 2; A0 is never driven, so DMA is word
aligned. 23 word bits cover 16 MB (DECISIONS O-11). Neither the '374s
nor the '193s (CLR grounded) see a reset: their power-up content is
arbitrary and the firmware always loads all three bytes before arming
(`dma_addr.sv` header).

SOURCED (6508 ROM e210-e243 ConfigDMAadr; 8049 ROM 0x025F): both
firmwares send 0xFB, LD2 byte, 0xFD, LD1 byte, 0xFE, LD0 byte, then
0xF7. The 6508 rotates its 16-bit byte address right by one before the
split, which is the word/byte conversion. The 6508 sends 0x7F before
every arm; the 8049 sends 0xFF before its arms and 0x7F only when a run
is over (section 6).

SOURCED (sheet 18; DECISIONS D-BUS-6, O-8): while /DMAEN is Low the
address chips drive A23:A1, U80 Q7 drives BR/W (1 = memory read), the
MMU is bypassed (/NOMMU Low) and the cycle is a word cycle. OPEN O-8:
ST during DMA (the spec says 1000, the Design Review 0100; the core
uses 1000), and whether the MMU address buffers U6/U7 are disabled.

## 5. The DMA engine

SOURCED (315046 sheets 8-10): a memory cycle is T1 (/MREQ Low, address
valid), T2 (/DS Low; /WAIT sampled on the CLK rise; a write drives the
word, a read takes it), T3 (/DS High, /MREQ High at least 135 ns after
/DS for DRAM precharge, CLKADR pulse). Minimum three CLKs, 500 ns per
word at 6 MHz.

SOURCED (sheet 3, sheet 8): /BUSREQ asserts when the FIFO wants work,
"minimum 4 us of data" before a request. INFERRED thresholds
(`dma_fsm.sv`, sheet 8 envelope): with DIR = read it asks while fewer
than 32 bytes are held and keeps the bus until 64; with DIR = write it
asks when a full word is present. OPEN O-8/O-11: the depth (64, from
sheet 6 "16 usecs at most for a 64 byte deep FIFO") and the exact
write-side threshold are not transcribed numbers.

SOURCED (sheet 9): byte-to-word funnel; the even byte of a word is
AD15:8, the odd byte AD7:0.

Block end. SOURCED (sheet 7): a block is 256 words after an LD0 arm;
DMADONE then goes High. SOURCED (CCCP spec 96-000016 4.1.28): _EST is
set at the end of a block and "reset whenever a DMA cycle is started by
LD0-" (`est_latch.sv`). OPEN O-9: whether the end is counted on the
memory side, the B side, or both (the core needs both).

## 6. Interrupts

Host -> controllers. SOURCED (sheets 3, 4, 7): a write to the IO/6 port
with /DS Low pulls _IREQ Low; PCSS 0x9F releases it. SOURCED (`wd.c`
410, 444; BIOS 00:1134): the kernel writes `out(WDIO, 1)` to start and
`out(WDIO, 0)` after the interrupt. INFERRED O-3: a write with AD7:0 =
0 clears _IREQ instead of setting it; the HD boot fails without this
rule in the model, and no document states it. A scope on _IREQ during
an `OUTW 0x0500,0` settles it.

Controllers -> host. SOURCED (sheet 7): PCSS 0xBF pulls /VI Low. The
chip sits in the chain CIO U70 -> SCC U74 -> CIO U66 -> 8716 -> CN11
(DECISIONS D-BUS-4). SOURCED (sheet 3): with IEI High, /IACK and /DS
Low it drives the vector on AD7:0. SOURCED (Floppy Specification 1.1
"vectored interrupt number 80"; Coherent `wd.c` WDVEC = 0x80): the
vector is 0x80 (`int_unit.sv` VECTOR). An earlier reading of the
specification's "80" as decimal (0x50) was wrong: the kernel source
settles it and boots with 0x80. OPEN O-4/O-5/O-21/O-22: IEO after the acknowledge, what
releases /VI (the core: the /DS fall of the acknowledge), whether IEI
gates /VI, and AD15:8 during the acknowledge.

End-of-block _IREQ, INFERRED (`int_unit.sv`, marked INFERRED in the
RTL). The 8049 ROM waits for a T0 rise at the end of every sector of a
multi-sector command (loop 0x0318-0x037C: 0x033B/0x033D wait INTRQ or
T0; 0x0427 pushes fill bytes until T0) and nothing but U790 pin 29
drives T0 (card sheet 2, sheet 18). No document gives the rule. The
rule in the core: PCSS 0xFF sets an enable, 0x7F and /RESET clear it;
while it is set, the end of an LD0-armed block pulls pin 29 Low (never a
single-step word); 0x9F, LD0, 0x7F, an IO/6 write of zero and /RESET
release it. Evidence: 0xFF/0x7F is the only difference between the two
firmwares' arm sequences (6508: 0x7F before every arm; 8049: 0xFF before
every arm, 0x7F only after the run), and the unconditional alternative
(pin 29 = IREQ OR EST, as the Commodore test rig's /BOTH jumper offers)
makes the parked 8049 wake on floppy block ends and fight the 8723 for
/PCSS. Multi-sector raw HD reads and the Coherent `Ftwd8.c` cylinder
tools depend on it; the kernel's block I/O (one sector per command)
does not. OPEN O-37: a logic analyser on CN9 22/28 at the end of an HD
sector and of a floppy sector on a C900 with the HDC fitted, or the CCCP
source listing 75-000006.

## 7. Sharing between the two cards

SOURCED (sheet 18, floppy sheets 13-14, HDC card sheet 2): both cards
drive /PCSS, /PCSD and BD through their own 74LS245 (floppy U202, gated
by 8723 pin 14 BUFFEN and steered by pin 23 OMADIR; HDC U5 and U9
'367, gated by WEN- from the 8049's WCS- port bit). No wire tells one
card the other is busy. _IREQ reaches both sub-CPUs.

SOURCED (Coherent `wd.c`: one `wdtab.wdu_active` mutex for floppy and
hard disk; BIOS boot probes the drives in sequence; Floppy Spec 2.16
"the firmware just hopes only one card strobes at a time"): both MCUs
wake on _IREQ, each reads its own 16-byte command block (HDC at
0x080000, FDC at 0x080010) with a single-step word, and the one whose
block is not armed (`c_errorbits` != 0xFF) returns to its idle loop.
The idle loops (8049 0x0040 `JNT0`; 6508 e0f7 motor timeout polling)
touch the 8716 no further. INTEN (CN9 34, 8049 HINT- to 6508 P7) is a
hand-over token: Low only in the 8049's not-my-command window
0x005B-0x005F, sampled by the 6508 at IRQ entry (e130). INFERRED: the
brief overlap of the losing card's sentinel read with the winner's
setup is what the chip tolerates on silicon; the core resolves the
shared lines Low-wins and logs contention (none seen in boots).

## 8. How we learned it

- 315046 drawing in "CBM900 special chips" (pins, commands, timing,
  DMA cycle). Sheets 3 and 7 give the /VI trigger as 0xF7 in one place
  and 0xBF in another; the firmware uses 0xBF (6508 e1db).
- Z8000 motherboard sheets 13, 14, 18, 19 (Pleban scan pp. 146-151) for
  the nets, CN9 and the TTL chips.
- 6508 ROM (e210-e264 DMA routines, e130-e171 IRQ entry) and 8049 ROM
  (0x0040 idle, 0x025F arm, 0x0318-0x037E sector loop, 0x02E3/0x02E8).
- Coherent `drv/wd.c` and `Ftwd8.c`, BIOS 00:1134 for the host side.
- The Go simulator, then the RTL, replaying 64 recorded vectors and the
  HD/floppy boots (0 contention samples, 359 sector reads + 2 writes in
  an HD single-user boot).

## 9. Open questions

| Id | Question | Settles it |
|----|----------|-----------|
| O-1 | /PCSS latch edge | scope |
| O-3 | IO/6 write with data 0 clears _IREQ | scope on OUTW 0x0500,0 |
| O-8, O-11 | FIFO depth, /BUSREQ thresholds | bench 8716 |
| O-9 | _EST set side | scope at a sector end |
| O-15, O-39 | byte vs select-line decode; PCSS 0x00 | bench 8716 |
| O-17 | pin 3 from Y5 or Y6 | meter U79.3 |
| O-18 | /WAIT wired to the chip | board inspection |
| O-37 | end-of-block pin 29 rule | analyser on CN9 22/28 |
| O-8 (bus) | ST during DMA, U6/U7 during DMA | scope or board inspection |
