# HR display card (Rev 5): the custom logic

The high-resolution bitmap card in the display slot (CN11/CN12). Its
logic is nine hand-drawn sheets FN#1-FN#9 (Rev 5, Nov 1984) and one
spec, the "Commodore 900 High Resolution Video Card" document. No part
on it is dumped: the sequencer and the six PALs are INFERRED programs
that reproduce the measured video and the firmware's use. Sources:
the HR spec (Pleban scan pp. 116-134, cited "spec"), the FN sheets
(pp. 135-143), the Z8000HR Hardware Specification sec 3.1/3.3/3.10,
the board photographs, a scope measurement of the stock mode, the BIOS
and Coherent's `hrtty` driver.

Legend: SOURCED / INFERRED / OPEN as in PDMAC_8716.md. RTL:
`rtl/hr_display/hr_card.sv` and the files named per block.

## 1. What is on the card

SOURCED (FN sheets; photos):

| Block | Sheet | Parts | Role |
|-------|-------|-------|------|
| FN#1 | ECL shifter, Rev 5 | U101 MC1648 96 MHz VCO, U103 MC10141, U104 shifter, U105 MC10125 | mono serialiser: 4 pixels per 24 MHz clock |
| FN#2 | memory control, Rev 5 | U207 74S161, U262 82S105 "SYN", U261 HC4040, U208 ZSEL 16L8, U211 ZARB 16R8, U209 ZMEMC 16R8, U210 ZCAS 16R8, JP3 | sync, arbitration, DRAM strobes |
| FN#3 | address mux, Rev 5 | U312 LS174, U315/U317 HC4024, 74S153 muxes, LS374 latches | control register, fetch counter, row/column mux |
| FN#4 | memory array, Rev 5 | 16 x M5M4416 (16K x 4) | one 128 KB bitmap, 64 bits wide |
| FN#5 | data latches, Rev 3 | 4 x LS373, 4 x LS374 | CPU read/write path |
| FN#6 | shift registers, Rev 3 | 4 x LS374, 4 x 74S299 | the four planes to pixels |
| FN#7 | mouse, Rev 5 | U755 PAL16L8, U754 LS374, U756/U757 PAL20X8 | ports 0x400-0x406 |
| FN#8 | connectors | J1 DIN, J3 DB-9, J4 power with a 7905 for -5 V | |

Our earlier model came from the Rev 3 sheet set ("Z8000 HR Display Card
Schematic"); FN#1-FN#4 and FN#7 are Rev 5 and differ (SYN is an 82S105,
not a PAL; the mouse is two PAL20X8s, not LS193s). The Rev 5 sheets
and the board photo govern.

```
 96 MHz VCO -> /4 -> 24M -> U207 /16 -> T8 = 1.5 MHz -> U262 SYN -> DE, HSYNC, -VSYNC, -VBLANK, H CNT, CNT RES
                                                              U261 line counter (Q1-Q11 back into U262)
 Z-Bus (A23-A17 = 0011111) -> ZSEL -> ZARB -> ZMEMC/ZCAS -> 16 x 4416 (64-bit rows) -> FN#6 S299 -> RGBI (24 MHz)
                                                                                         -> FN#1 U104 -> mono (96 MHz)
 I/O 0x400-0x406 -> U755 -> U756/U757 (X, Y counts), U754 (buttons), U312 (control)
```

## 2. Modes and the jumper

SOURCED (spec sec 1, 3.2; FN#2 p. 136; photos): three modes, chosen by
the two straps of JP3 (M/C to U262 pin 6 and U756/U757 pin 7; 4PC to
U262 pin 5; pulled up when open). No register selects a mode: the
control register bits are bank, enable and intensity only. The
production card photographed has JP3 open and runs 1024x800.

| Mode | JP3 | 404H read F1:F0 | Bits/pixel | Row stride | Bitmap |
|------|-----|-----------------|------------|------------|--------|
| 1024x800 mono (stock) | both open | 2 | 1 | 128 bytes | 102400 bytes |
| 1024x1024 mono | 4PC linked | 3 (spec); 2 on this card, see sec 5 | 1 | 128 | 131072 |
| 640x400 RGBI | M/C linked | 1 | 4 | 320 bytes | 128000 |

INFERRED: M/C linked = colour, 4PC linked alone = 1024 lines (M/C is
the only line named mono/colour; 4PC is the only other mode line). The
spec's other names for the 4PC glyph ("NPC") are not resolved. OPEN: a
card with the straps fitted.

## 3. The bitmap and the CPU path

SOURCED (spec sec 3.1; Z8000HR 3.1 segment map; BIOS and kernel):
physical 0x3E0000-0x3FFFFF (segments 0x3E, 0x3F), linear across the
boundary; pixel (0,0) is the first word; mono: bit 15 of a word is the
leftmost pixel, 1 = lit, 64 words per row; colour: 4 pixels per word,
pixel 0 in bits 15:12, nibble = I R G B, 160 words per row. Coherent
maps logical segments 0x3A/0x3B onto 0x3E/0x3F (`hrtty` portst_).

SOURCED (spec 3.2.2.1; photo): the bank bits B1:B0 move the bitmap
base among 0x380000/0x3A0000/0x3C0000/0x3E0000 only with 256K DRAMs; the
Rev 5 card carries 16 x 4416 = one 128 KB bank, so the bits do nothing
and the bitmap is always at 0x3E0000. The BIOS and kernel write 11.

INFERRED (FN#2, `hr_zsel.sv`, `hr_zarb.sv`, `hr_zmemc.sv`,
`hr_zcas.sv`, `hr_fn4_dram.sv`, `hr_fn5.sv`): ZSEL decodes A23-A17 =
0011111 with -BMREQ and holds -WAIT until ZARB reports the access
served; each 1.5 MHz count has a CPU half (RAS counts 1-6, -CDONE at 6)
and a display half (RAS 9-14, XCLK at 15), so a CPU access waits 1 to
5 Z8001 wait states in every mode, display active or not. A read
latches the whole 64-bit row at -CDONE and drives the addressed word
onto BAD while -BDS is Low; a write is an early write of the strobed
bytes at the CPU CAS edge. Evidence: the PAL pin names and nets on FN#2
(-CREQ, -CDONE, MUX, WE, the eight CAS strobes 1H..4L), U207's T1-T8
outputs as the PAL inputs, and the Rev 3 sheets' timing notes; the
programs themselves are undumped. OPEN: the real wait-state count (a
scope on -WAIT during a kernel scroll).

## 4. Sync and timing (U262 SYN)

SOURCED (FN#2 p. 136; FN#1 p. 135): U101 96 MHz VCO; U103 divides by 4
to 24M; U207 74S161 divides 24M to T1/T2/T4/T8 (12/6/3/1.5 MHz); U262
82S105 is clocked by T8, its inputs are its own DE, HSYNC and H CNT,
M/C, 4PC and the eleven outputs of U261 (HC4040 line counter, clocked
by H CNT, cleared by CNT RES); outputs F0-F7 = DE, HSYNC, H CNT,
-HSYNC, -VSYNC, -VBLANK, DE DLY, CNT RES. The sheet carries the note
"H sync = 53.6 KHz" = 1.5 MHz / 28.

SOURCED (scope on a production card, 1024x800): HSYNC 53.4 kHz
positive TTL, VSYNC 60 Hz negative TTL, 890 lines. The VCO trimmer
accounts for 53.4 vs 53.6 kHz.

INFERRED pixel rates (FN#6: the four 74S299 shift at 24M; FN#1: U104
loads the nibble and shifts it at 96 MHz): colour 24 MHz, one nibble
per 24M clock; mono 96 MHz, four pixels per clock. One count = 64 mono
or 16 colour pixels = one 64-bit row fetch.

INFERRED frame (`hr_u262.sv` with the generated program
`hr_syn_prog.svh`; `hr_syn.sv`); the porch split is a choice that
reproduces the measurements, not a dump:

| | 1024x800 | 1024x1024 | 640x400 |
|---|---|---|---|
| H active / front / sync / back (counts) | 16 / 1 / 3 / 8 = 28 | same | 40 / 2 / 3 / 3 = 48 |
| Line | 18.667 us, 53.57 kHz | same | 32.0 us, 31.25 kHz |
| V active / front / sync / back | 800 / 3 / 3 / 87 = 893 | 1024 / 3 / 3 / 87 = 1117 | 400 / 50 / 2 / 69 = 521 |
| Frame | 59.99 Hz | 47.96 Hz | 59.98 Hz |

The colour line must be 48 counts (640 pixels at 24 MHz = 40 counts do
not fit 28), which is why M/C reaches the sequencer. The whole-machine
spec's "1024x1024, 32 kHz interlaced" describes an earlier 6545-based
design, not this card. OPEN: the 82S105 fuse map, or a scope on H blank
and -VBLANK in all three modes.

Fetch counter (FN#3, `hr_fn3_xp.sv`): U315/U317 HC4024 cascade into
XP0-XP13, clocked by ZMEMC XCLK, cleared by CNT RES; the row address of
the display fetch. Shift path (FN#6, `hr_fn6.sv`): -OE1/-OE2 put row
bytes 0-3 and 4-7 on MD31-0 in turn; plane p's LS374 takes MD bits
4k+p, loaded into its 74S299 by SR LD; U104 (FN#1) takes the four QH'
outputs each 24M clock.

## 5. I/O ports (FN#7 and FN#3)

SOURCED (spec 1.1, 3.2, 3.3; Z8000HR 3.10): U755 takes -IO4 (0x04xx),
A4, A1, ZCLK, BR/W, -BDS; A2 goes to U756/U757; A0 is ignored.

| Port | Dir | Contents | Evidence |
|------|-----|----------|----------|
| 400H | R | 9:0 X count, 15/14/13 buttons B1/B2/B3 | spec 1.1, 3.3 |
| 402H | R | 9:0 Y count, buttons | spec fig 3-6 |
| 404H | R | 1:0 mode F1:F0 (0 no HR card, 1 colour, 2 1024x800, 3 1024x1024) | spec 3.2.1; Design Review 1.x |
| 404H | W | control register | spec 3.2.2; BIOS 00:2120 `OUTB 0404H, FFH` |
| 406H | R | 1:0 = 00: no text card | spec 3.2.1 |
| 414H | W | the same control register | Coherent `hrtty` v0load `outb(0x414, 0xff)` |

Control register, SOURCED (spec 3.2.2; FN#3 U312 LS174 cleared by
/MRESET, `hr_u312.sv`): B0/B1 bank select (inert on this card), B2
mono enable (0 = black), B3 mono intensity (1 = 100 %, 0 = 80 %), B7:4
reserved. Reset value 0: the screen is black until software writes it;
both the BIOS and the kernel write 0xFF. B2/B3 act only on the mono
path (U102 MONO EN, U106 +EI); the RGBI pins leave FN#6 directly.

INFERRED (U755 pins; `hr_u755.sv`): -SEL X/Y = I/O read with A1 = 0/1,
-SEL W = I/O write with A1 = 0, -SEL Z = read with A4 = 1. U755 has no
A2, so 414H decodes as 404H (the kernel's write confirms it), a write
to 400H would also load the register (nothing does), and 404H/406H
reads select the mouse PALs like 400H/402H: U756/U757 see A2 and M/C and
put the mode constant on bits 1:0 (U756: M/C open 10, linked 01;
U757: 00). Consequence: 1024x1024 reads 2, not 3; read 404H only to
tell mono from colour. An equally consistent alternative, not taken:
A2 High disables the drive and 404H/406H read a floating bus.

Byte lane, INFERRED: a Z8001 OUTB drives D15:8 and duplicates a byte
write on both halves; the register latches the byte on BAD. OPEN
(measurement sheet 13b): the lane the 404H read returns on.

## 6. The mouse (FN#7)

SOURCED (spec fig 5-3; photo of U754/U756/U757, MMI date 8505): J2
male DB-9, Amiga pinout: 1 Y(A), 2 X(A), 3 Y(B), 4 X(B), 5 B2, 6 B1,
7 +5 V, 8 GND, 9 B3; buttons pulled up by a 3.3 k pack. Counts are
10 bits, free-running, never reset; right increments X, down
increments Y (spec 3.3). Buttons: bit 15 B1 (left, MLEFT), 14 B2
(middle), 13 B3 (right), 1 = pressed (Coherent `desk.h`, `dmesg.c`
polarity), on both 400H and 402H.

INFERRED (`hr_fn7.sv`, `hr_pal20x8.sv`): MCLK = ZCLK; U754 samples
each quadrature line and its previous sample on MCLK; each PAL20X8
holds eight registered bits (BAD9-2) stepping +1 when the Gray phase
wraps 3 -> 0 and -1 the other way, with the phase itself on BAD1-0.
Evidence: the kernel reads 10 bits (`hr.h` MBITS 10) and sign-extends
the difference; a PAL20X8 has eight XOR macrocells; the draft sheet's
LS193s were never fitted. OPEN: U756/U757 and U755 fuse maps (whether
the low two bits are the phase or a carry extension in U754).

No interrupt: Coherent polls at 100 Hz; the cursor is a software XOR
sprite (hr2.c). The core also offers a serial Mouse Systems mouse on
SCC channel A: INVENTED, DECISIONS D-SER-5 (user 2026-11-15), not
part of this card.

## 7. Connectors and levels

SOURCED (spec figs 5-1/5-2, p. 142): J1 mono DIN (10 contacts drawn,
DIN-8 fitted): 1 -ECL video, 4 +ECL intensity, 5 VSYNC, 7 +ECL video,
8 HSYNC. J3 RGBI DB-9 female (footprint, unfitted on the photographed
card): 3-6 R, G, B, I (TTL, from FN#6), 7 mono video as TTL (U105), 8
HSYNC, 9 VSYNC. OPEN: the real-board measurement found HSYNC on DIN
pin 7 and VSYNC on 5, against the drawing. SOURCED (owner report,
2026-11-02): with J3 fitted, 1024x800 drives a VGA LCD directly (53.6
kHz / 60 Hz is near 1152x864@60).

The core outputs the card's RGBI and mono bits one for one; the
monitor levels (0xFF/0xCC mono, 0xFF/0xAA colour) are a display choice,
DECISIONS D-VID-2.

## 8. How Coherent uses it

SOURCED: BIOS writes 404H = 0xFF after the probe; `hrtty` writes 414H =
0xFF, maps 3A/3B -> 3E/3F, clears 1024x800; console cells 12x25 pixels,
85 x 32; BEL inverts the top 50 lines and back (about 110 ms). The
kernel console is hard-wired to 1024x800 (`hr.h` XMAX/YMAX).

## 9. Open questions

| Question | Settles it |
|----------|-----------|
| U262 program (porches, -VBLANK) | 82S105 dump or scope on all U262 outputs |
| ZSEL/ZARB/ZMEMC/ZCAS programs; wait-state count | PAL dumps; scope on -WAIT and the CAS strobes |
| JP3 mapping (4PC) | a card with straps fitted, or the glyph on a better scan |
| U755/U756/U757 programs; 404H/406H read bits | dumps; read 404H on a 1024x1024 card |
| 404H read byte lane | measurement 13b |
| J1 pin numbering | board check |
| mono intensity 80 % level | scope on +ECL intensity |
