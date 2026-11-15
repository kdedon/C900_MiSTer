# LR display card: the custom logic

The low-resolution card: 80x25 text on an HD6545 CRTC, plus two Z8030
SCCs for four RS-232 ports. Its custom parts are two dumped 82S100
PLAs, U18 "ZRSEL" (bus decode) and U22 "4A75" (attribute decode), and
one undumped PAL16R6A, U13 (dot-clock sequencer). The 6545 and the SCCs
are public parts; this file covers only how the card wires them.
Sources: the LR card schematic, five typed sheets 47-51 ("Data Bus",
"Address Bus", "Serial I/O A/B", "Video", "Serial I/O C/D"), the two
PLA dumps, the character ROM dump, the BIOS and Coherent's `mm.c` /
`al.c`.

Legend: SOURCED / INFERRED / OPEN as in PDMAC_8716.md. RTL:
`rtl/lr_display/c900_lr_card.sv`, `lr_u18_zrsel.sv`, `lr_u22_attr.sv`
(both generated from the dumps), `lr_u13_pal.sv` (INFERRED), `lr_cdr.sv`,
`lr_pixel_path.sv`, `mc6845_lrdisp.sv`.

## 1. What is on the card

SOURCED (sheets 47-51; parts inventory):

| Ref | Part | Role | Sheet |
|-----|------|------|-------|
| U18 | 82S100 "ZRSEL 02 1A93" | bus decode: CDR select, I/O selects, 6545 E | 48 |
| U13 | PAL16R6A | dot-side sequencer: CCLK phases, VRAM slot, /WAIT, write strobes | 48 |
| U22 | 82S100 "380212-02 4A75" | attribute and cursor decode | 50 |
| U30 | 16.257 MHz oscillator | dot clock | 48 |
| U24 | 74LS163A | divide by 9: CCLK and S-L | 48 |
| U5, U6 | 2016 2K x 8 SRAM | character display RAM (CDR), one 16-bit word per cell | 48 |
| U16, U17, U26 | 74LS157 | CDR address mux, CPU side / MA side | 48 |
| U9 | HD6545 (HD46505) | CRTC | 47 |
| U7, U8 | 74LS646; U29 74LS245 | BAD <-> VD data path | 47 |
| U23, U33 | 74LS74A | ENVID, EN_LINK flags | 47 |
| U3, U4, U21 | 74LS374, 74LS273, 74S374 | character and attribute latches | 50 |
| U2 | 2332 "380217-01 R.3 PC CHAR" | character ROM, dumped | 50 |
| U1 | 74LS166 | pixel shifter | 50 |
| U20, U12 | 74LS393, 74LS175 | blink dividers | 50 |
| U31 | Z8030 | SCC #1, channels A/B to CN3/CN4 DB25 | 49 |
| U36 | Z8030 socket | SCC #2, channels A/B to CN5/CN6 headers | 51 |

SOURCED: the card has no keyboard interface (an earlier reading of
"shift register" as a keyboard SIO was wrong: U1 is the pixel shifter).

```
 Z-Bus BAD15:0 -> U29/U7/U8 -> VD15:0 -> U5/U6 CDR (CPU side, A11:1)   seg 0x37
                                       -> U9 6545 (0x0410/0x0412)
 U30 16.257 MHz -> U24 /9 -> CCLK 1.806 MHz -> U9 -> MA10:0, RA, DE, CURSOR, HS, VS
 CDR (MA side) -> U3 char -> U2 ROM -> U1 shifter -> glyph bit --+
                 U4/U21 attribute -> U22 -> polarity/blink/cursor --+-> VIDEO, INTENS, syncs -> CN2
 U18: _I-O4 (0x04xx) -> _6545, _CTL (0x0418 W), _STAT (0x041C R); _I-O3 (0x03xx) -> U31/U36 by A7
```

## 2. U18 ZRSEL: the decode

SOURCED (dump `C900 ZRSEL 02 1A93 U18 82S100 bbfe6b73.bin`; sheet 48
at 900 dpi for the pin nets). Pin map as wired:

| I | Net | I | Net |
|---|-----|---|-----|
| I0 | A0 (unused by every output) | I9 | BW-R (1 = write) |
| I1 | A2 | I10 | BB-W (unused) |
| I2 | A3 | I11 | _BMREQ |
| I3 | A4 | I12 | _BDS |
| I4 | U27: A16 & A17 & A18 | I13 | _I-O4 |
| I5-I8 | U28: /(A20 & A21), A19, A22, A23 | I14 | _SUP |
| | | I15 | _CCLK (unused) |

Equations (deassert form; from the dump):

```
F0 _CDR    = !I4 | I5 | I6 | I7 | I8 | I11 | !I14      memory cycle, segment 0x37, supervisor
F1 _SELI-O = !I3 | I13                                  any card I/O cycle (A4 = 1, _I-O4)
F2 _CTL    = I13 | !I9 | !I2 | I1 | I12 | !I3           I/O write, A3 = 1, A2 = 0, at _BDS: 0x0418
F3 _STAT   = !I1 | I9 | !I2 | I13 | !I3                 I/O read, A3 = 1, A2 = 1: 0x041C
F4 _6545   = I13 | I1 | I2 | !I3                        A3 = A2 = 0: 0x0410/0x0412 (RS = A1)
F5 PH2     = !I1 & !I2 & I3 & !I12 & !I13  (active High)  the 6545 E strobe
F6, F7     = 0 (unused)
```

Read as a map:

| Address | Select | Use |
|---------|--------|-----|
| memory 0x370000-0x370FFF | _CDR | 2K x 16 text cells, supervisor only (I14); even byte = character, odd = attribute; MA = A11:1 |
| I/O 0x0410 / 0x0412 | _6545, RS = A1 | CRTC address / data register |
| I/O 0x0418 write | _CTL | control latch (section 5) |
| I/O 0x041C read | _STAT | status; nothing on the card drives data for it (OPEN) |
| I/O 0x0300-0x037F | U31, CS1 = /A7 | SCC #1: channel A 0x0300, B 0x0320 |
| I/O 0x0380-0x03FF | U36, CS1 = A7 | SCC #2: channel A 0x0380, B 0x03A0 |

SOURCED (Coherent `al.c` altty[]: 0x0100, 0x0120, 0x0300, 0x0320,
0x0380, 0x03A0; `mm.c`: "bit 0 of the memory address determines
character or attribute", 11 address bits to the controller). The
interrupt chain enters at CN11 pin 33, U31 then U36 (DECISIONS D-BUS-4).

## 3. U13 and the CDR timing (INFERRED)

SOURCED (sheet 48): U24 runs 0..8 and clears (divide by 9; /CLR =
/QD), QC inverted = CCLK to the 6545, QD = S-L to the U1 shifter; U13
inputs are U24 QA-QD, BW-R, A0, U18 F0 (CDR) and BB-W; outputs
_SELMBUF, MUX-CLK, _OE, _W1, _DATCLK, _W2 (registered on OSC) and _WAIT
(combinational). So a character cell is 9 dots, 553.6 ns, and the
character clock is 1.8063 MHz.

INFERRED (`lr_u13_pal.sv`, `lr_cdr.sv`; U13 undumped): each
character time has one CRTC fetch (end of dot 8) and one CPU slot; a
CPU CDR access holds /WAIT until the next slot, then is served, so the
CPU waits up to one character time. _W1 writes the character SRAM
(U5), _W2 the attribute SRAM (U6): a word write writes both, a byte
write only U5 whatever A0, from the lane A0 selects (_SELMBUF). The
evidence is the BIOS: BvidCHR byte-writes characters at even addresses
and the kernel writes words of (attribute << 8 | character); a /WAIT
term that waited for /DS lost writes in the bench. OPEN: a U13 dump or
a scope on /WAIT and _W1/_W2 (bench offset of about 2400 Z8001 clocks
in the BIOS screen clear against the simulator, DECISIONS D-TB-3).

## 4. The CRTC programming

SOURCED (BIOS 00:425C loop over the table at 00:434A, 16 pairs):

| R | Value | Meaning |
|---|-------|---------|
| R0 | 0x61 | 98 characters per line: 54.25 us, 18.43 kHz |
| R1 | 0x50 | 80 displayed |
| R2 | 0x52 | sync at character 82 |
| R3 | 0x0F | 15 characters of HSYNC |
| R4 | 0x19 | 26 character rows total |
| R5 | 0x06 | 6 extra lines |
| R6 | 0x19 | 25 rows displayed |
| R7 | 0x19 | VSYNC at row 25 |
| R8 | 0x02 | interlace mode bits = 10 |
| R9 | 0x0D | 14 scan lines per row |
| R10, R11 | 0x0B, 0x0C | cursor lines 11-12 |
| R12-R15 | 0 | start address and cursor at 0 |

Frame: 26 x 14 + 6 = 370 lines, 49.8 Hz at the 18.43 kHz line. The
kernel's `mm.c` carries the same values as "monochrome settings 80x25"
(for an MDA-style card) and programs only R10, R12, R14-R15 at run
time (cursor shape, page, cursor position). OPEN: how the HD6545 treats
R8 = 2 (interlace sync and video) on this card: the simulator and the
core run it as a 370-line non-interlaced frame and the picture is
right; a scope on VS settles the field structure. The 18.4 kHz line is
why the core gives this card the scandoubler (DECISIONS D-VID-3).

Glyphs: U2 is a 2332 (4 KB), addressed by the character code (VD7:0
through U3) and RA3:0; 8 dots wide, the ninth dot repeats bit 0 for
codes 0xC0-0xDF (box-drawing continuity; gate untraced) else blank. The
dump `C900 380217-01 R.3 PC CHAR U2 TMS2532 64cb4171.bin` is the IBM
PC character set.

## 5. The control latch and status

SOURCED (BIOS 00:422E `OUTB 0x0418, 0`; 00:4272 `OUTB 0x0418, 0x28`
after the CRTC table; sheet 47): _CTL clocks a latch whose bits feed
U23/U33 (ENVID, EN_LINK), cleared by _MRESET. INFERRED: 0x28 turns the
video on after programming (ENVID); the bit assignment is untraced and
the core holds the value only. OPEN: a trace of the latch outputs on
sheet 47, and what _STAT (0x041C) returns (the 6545 drives only
R14-R17; nothing else on the card drives data for that select).

## 6. U22: attributes and cursor

SOURCED (dump `C900 380212-02 4A75 U22 82S100 7889163e.bin`): outputs
F0-F4 are one function on five pins (cell video polarity, "VID"), F5 =
cursor, F6 = glyph suppress (blink), F7 a third attribute decode;
inputs: I0 CURBL_INK, I1-I3 cursor group, I15 ENBL_INK (character
blink phase), I6/I8/I11 raster selectors, and the attribute byte on
I4, I10, I13, I7, I12, I9, I5, I14 for b0..b7. U22 does not see the
pixel: the glyph bit is combined downstream (U25 and glue):

```
vid = F5 | ((glyph & !F6) ^ !VID)      gated by DE
```

The attribute map is INFERRED by constraint solving (8! assignments
against the kernel's vocabulary) with the straight-routing reading of
sheet 50 as the tie-break; it is the straight map with b3 and b7
swapped. The kernel (`mm.c`) writes the IBM MDA vocabulary:

| Attribute | Kernel name | Rendering (from the dump under the solved map) |
|-----------|-------------|-----------------------------------------------|
| 0x07 | ATT normal | lit glyph on dark |
| 0x70 | REVERSE | dark glyph on lit cell |
| 0x01 | UNDERL | normal, plus the underline row (RA = 12, I8) lit |
| 0x08 bit | INTENSE | brightness only (b3 = I7, near-inert in the dump; INTENS leaves on its own line) |
| 0x80 bit | BLINK | glyph suppressed in the off half of ENBL_INK (16 frames on, 16 off) |
| 0x00 | | identical to 0x70: b0 (I4) gates every output, so a zeroed attribute renders as reverse video |

Closed forms off the underline row: VID = b0 & (!b6 | b7 & !ENBL),
F6 = b0 & b7 & !ENBL (verified against the dump for all 256 attributes
x 4 raster states). Cursor: F5 = CURBL_INK & !I1 & I2 & I3; the core
feeds I0 = 6545 CURSOR with I1-I3 fixed so F5 = CURSOR. OPEN: the nets
of I1-I3, I6, I8, I11 and the ENBL_INK divider tap (U20), the ninth-dot
gate, and the INTENS path to CN2; a sheet 50 scan above 900 dpi or a
board trace.

## 7. Serial

SOURCED (sheets 49, 51; `al.c`): U31 _CS0 = _I-O3 with CS1 = /A7, U36
_CS0 = _I-O3 with CS1 = A7; PCLK = the backplane _CLK; DB25 CN3/CN4
carry full RS-232 (DTR, DSR, DCD, RTS, CTS) through line drivers; CN5/
CN6 are headers. SOURCED (DECISIONS D-SER-4, user 2026-11-04): the
core always fits U36. INFERRED (DECISIONS D-BUS-12): the Z8030 takes
one access per /AS, so the 8716's /DS-only DMA cycles do not touch it.

## 8. How we learned it

- The two PLA dumps (65536-byte truth tables), minimised and checked
  against the Coherent I/O map and attribute vocabulary; regression
  tests hold the dumps as oracles.
- Sheets 47-51 (typed, read at 900 dpi; trunk bundle numbers give the
  net identity), the parts inventory.
- The BIOS CRTC table and `mm.c`, `al.c`.
- The character ROM dump.
- The simulator and the core display the BIOS and Coherent console
  correctly with these models; the U13 schedule is inferred.

## 9. Open questions

| Question | Settles it |
|----------|-----------|
| U13 program: /WAIT width, slot phase, write strobes | PAL dump or scope |
| control latch bits (0x28) and _STAT data | sheet 47 trace, board |
| R8 = 2 field structure | scope on VS |
| U22 I1-I3, I6, I8, I11 nets; blink tap; ninth-dot gate | sheet 50 re-read |
| INTENS to CN2 | sheet 50 re-read |
