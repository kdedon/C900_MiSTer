# Hard disk card: WD1003-CMD (68-000057)

A Western Digital controller card built for Commodore: an Intel 8049
("CCCP", U10) with 2 KB of mask ROM, a PAL16R6 (U8) that makes the host
strobes, the WD2010 Winchester controller (U12), the WD10C20 data
separator (U101) and ST-506 drive connectors. It plugs into
motherboard CN9 (its J4) and talks to the host only through the 8716's
OMAD bus. The WD2010 and WD10C20 are public parts; this file covers
the 8049 firmware, U8 and the card wiring. Sources: the WD1003-CMD
schematic 68-000057 (sheets 2-4), its parts list, the CCCP spec
96-000016, the 8049 ROM (`wdc_MCU_U10.bin`, addresses below), Coherent
`drv/wd.c` and the BIOS.

Legend: SOURCED / INFERRED / OPEN as in PDMAC_8716.md. RTL:
`rtl/hdc/c900_hdc_card.sv` (card), `rtl/hdc/pal_hdc_u8.sv` (U8),
`rtl/hdc/t48_wdc.sv` (8049), `rtl/hdc/wd2010*.sv`, `rtl/hdc/wd10c20.sv`,
`rtl/hdc/hd_image.sv` + `drive_st506.sv` (the drive, our board).

## 1. Parts and wiring

SOURCED (parts list, scan pp. 189-195; sheets 2-4):

| Ref | Part | Role |
|-----|------|------|
| U10 | CCCP, Intel 8049 family, IC 29-000085-00 | the MCU; XTAL from the host 6 MHz |
| U12 | WD2010-05 | Winchester controller |
| U8 | PAL16R6, Commodore 62-001019-10 | host strobe sequencer; no fuse dump |
| U9 | 74LS367A | PCSS-/PCSD- drivers to J4 |
| U5 | 74LS245 | card data bus <-> DMAD (OMAD) |
| U4 | 74LS00 | WDMA- and U5 direction |
| U2, U6, U13 | 74LS14 | host and drive status receivers |
| U7, U11 | 7406 | HINT- and drive control drivers |
| U101, U102, Y101, CR101 | WD10C20, 96 ns delay line, 10 MHz crystal, varactor | data separator; Y101 clocks only the WD10C20 |
| U14, U15 | 3487, 3486 | RS-422 MFM write/read |

Clock, SOURCED (CCCP spec; sheet 2): the 8049 runs from the host's 6
MHz (J4 26 -> U2 -> U7 x2 -> CPUCLK -> XTAL1/2 and U8 pin 1), 15
XTAL clocks per machine cycle = 2.5 us. The 10 MHz crystal gives the 5
Mbit/s MFM rate, 1.6 us per byte. An earlier theory that the 8049 ran
at 10 MHz was wrong (the XTAL trace runs to CPUCLK).

Host connector J4 = CN9: 2-16 DMAD0-7, 18 PCSS-, 20 PCSD-, 22 IREQ-,
26 6MHZ, 28 EST-, 30 RESET-, 34 INTEN; odd pins ground, 29 -12 V
(motherboard sheet 18, Rev C plot).

8049 pins (sheet 2; DECISIONS D-HDC-1):

| Pin | Net | Use |
|-----|-----|-----|
| T0 | IREQ- through U2 | High while the 8716 asserts _IREQ; the idle loop is `JNT0 0040` |
| T1 | EST- through U2 | the firmware never tests it |
| /INT | VINT = WD2010 INTRQ through U6 | polled with `JNI` |
| BUS (P0) | card data bus | WD2010 D7:0 and, through U5, DMAD |
| P1.2-0 | WD2010 A2-0 | register select |
| P1.3 | WCS- | Low selects the WD2010; High = WEN- Low = U5 and U9 toward the host |
| P1.5 | BCS (in) | WD2010 owns the data bus (buffer frame) |
| P1.6 | HINT- | Low drives INTEN High on CN9 |
| P1.7 | SMR- | resets U8's sequencer |
| P2.4, P2.5 | DS0-, DS1- | drive select, Low = selected (not the WD2010 SDH bits) |
| ALE | WD2010 BRDY | buffer ready; rises once per machine cycle |
| RD-, WR- | WD2010 RE-/WE- (through U9 section 2 while BCS is off) and U8 | register strobes and the host strobe triggers |

SOURCED (sheet 3): drive control through 7406 to J3 (DSEL, HSEL, RWC,
STEP, DIRECTION, WRITE GATE); status through 74LS14 (DRDY, SC, INDEX,
TK000, WF-). MR- = on-board power-on circuit OR host RESET- resets the
WD2010 and the 8049; U8 has no reset pin. Head select HS2-0 is latched
from the data bus by the WD2010's SDHLE- (latch designator untraced,
D-HDC-3).

The earlier C900 hardware reference gave P1.7 = PCSS, P1.3 = PCSD,
P1.5 = DRQ and the WD2010 BDRQ on the 8716's /CREQ: superseded by the
400 dpi read of sheet 2 (BDRQ and BCR are not connected).

## 2. U8: the host strobe sequencer

SOURCED (sheet 2, 400 dpi): pin 1 CLK = CPUCLK; 2 WCS-; 3 CVE- (8049
WR-); 4 ALE; 5 CRE- (8049 RD-); 6 WVE- (WD2010 WE-); 7 WRE- (WD2010
RE-); 8 WDMA- = NAND(BCS, NOT EST); 9 SMR-; 11 /OE grounded; 12 PCSD-
and 19 PCSS- (the two combinational I/O pins) to U9 section 1 (E- =
WEN-) and J4 20/18; 13-18 the six registered outputs, named NCR-,
DALE2-, LVE2-, LVE1-, ENDCYL-, QALE-, not connected (fed back).

SOURCED (CCCP spec 4.1.8-4.1.23): "data is transferred directly
between the WDC and the host, at a rate of 1.6 us per byte, without any
CCCP intervention"; the 8049 "statically latches" the OUTL BUS byte
when initialising the host DMA; with SMR- Low "no PCSS-, PCSD- strobes
are required to be generated via the state machine".

INFERRED equations (`pal_hdc_u8.sv`; no fuse dump), each forced by a
firmware access (ROM order: 0x0063, 0x00AE, 0x025F, 0x0200, 0x027A,
0x02A4, 0x033F, 0x035F, 0x0427):

- PCSD: a WD2010 buffer strobe (WRE-/WVE-) inside the WDMA window; an
  8049 read with WCS- High; an 8049 write with WCS- High that is the
  second of a pair or made while SMR- is Low.
- PCSS: any other 8049 write with WCS- High.
- Pair state registered on CPUCLK: it alternates after each write, SMR-
  Low or a read returns it to "PCSS next".

Constraints that fix this: the 7-write burst FB d FD d FE d F7 at
0x035F with no SMR- between; a read-count-independent return to PCSS
after the status poll at 0x0200; FIFO bytes written at 0x02AA and
0x042A under SMR- Low. OPEN O-23: product terms, encoding and timing
need a fuse read (or a DuPAL-style functional dump). OPEN O-32: whether
the OUTL strobes are ALE-timed after WR- (register names QALE/DALE2
suggest it) or inside WR- as the core does; a logic analyser on U8 pins
1-9, 12, 19 settles it. OPEN F-16: U8 power-up state (the firmware's
first instruction pulses SMR-, so no host access sees it).

The DMA data path, SOURCED (sheets 2-3; WD2010 data sheet): the 8049
arms the 8716 (LD2, LD1, LD0, F7) and writes the WD2010 command; the
WD2010 asserts BCS and moves 512 bytes with its own RE-/WE- while
_EST is High, each strobe becoming a PCSD through U8 and U5; the 8716
sets _EST at the block end and U4 closes the window. BRDY = ALE means
the WD2010 never waits long on the buffer, so a write relies on the
8716 having filled its FIFO first.

## 3. The 8049 firmware

SOURCED (ROM listing). Register bank 1 holds the 8716 command bytes
(R0' EF, R1' FB, R2' FD, R3' FE, R4' F7) and the DMA address (R5'-R7').
Internal RAM: 0x20-0x29 the command block, 0x2E heads, 0x33 sectors per
track, 0x35-0x37 the block address {04, 00, 00} = 0x080000, 0x3C
restore-needed flag, 0x3E-0x49 WD2010 task-file shadows for drives 0
and 1.

Main loop (0x0040): `JNT0` until T0; P1 = 08 (WCS- High: the host side
enabled), single-step read of word 0x0E of the block (the errorbits
byte). 0xFF means "not mine": P1.6 Low (INTEN High) until T0 falls, then
back to the loop. Otherwise 0x0063: PCSS 0x9F (release _IREQ), read the
10-byte block, validate the opcode (0x007A-0x0098: 0x00-0x0F or
0xE0-0xE6, else the error path 0x008F), dispatch through the page-0
table at 0x003F (`JMPP`).

| Opcode | Coherent name | Handler | Note |
|--------|---------------|---------|------|
| 0x00 | WDSDP (old) | 0x00C0 | |
| 0x01 | WDREST | 0x0403 | restore |
| 0x03 | WDRSS | 0x00A4 | request status: completes at once |
| 0x05 | WDCTF | 0x0449 | check track format |
| 0x06 | WDFMTT | 0x0438 | format track |
| 0x08 | WDREAD | 0x0304 | |
| 0x0A | WDWRITE | 0x03E9 | |
| 0x0C | WDSDP | 0x0400 | set drive parameters |
| 0x0F | WDCCBA | 0x0417 | change command block address (RAM 0x35-0x37) |
| 0xE3, 0xE4 | WDDDIAG, WDCDIAG | | accepted by the range check |

Handler addresses are INFERRED from the `JMPP` table bytes at
0x000A-0x001E and the `JMP` stubs at 0x0021-0x0033; READ and WRITE are
confirmed by the code there.

WDSDP block (Coherent `wd.c` WDP, sent once at open and by the BIOS
before the first read): options/step rate, heads and cylinder MSB,
cylinder LSB, precomp cylinder/16, reduced-write cylinder/16, sectors
per track. Default: 612 cylinders, 4 heads, 17 sectors, 16 us step,
precomp and reduced current from cylinder 128.

READ/WRITE (0x0304/0x03E9 -> 0x0100): the LBA in bytes 1-3 (bit 5 of
byte 1 = drive 1) is divided by sectors per track and heads in software
(0x0147-0x016E, 0x0125-0x0156) into the WD2010 task file; the DMA
address bytes 6-8 are rotated right once (word address) for LD2/LD1/LD0.
The first command after reset runs a RESTORE (0x3C = 0 -> 0x040D).
Sector loop 0x0318-0x037C: arm the 8716 (0x035F: FB d FD d FE d F7),
write the WD2010 command, wait BCS (0x0333), wait INTRQ or T0
(0x033B/0x033D), read status, re-arm for the next sector (block count
R5 and RAM 0x24 count down, address += 512). Read Sector is issued with
M = 1 (0x25) so the WD2010 steps through the sectors and interrupts
once; the T0 rise at each block end comes from the 8716 (PDMAC_8716.md
section 6, INFERRED rule). After an ECC correction (0x0427) the ROM
pushes zero bytes until T0.

Completion (0x00A4 CompleteCmd): the status byte is written to +0x0C
by a single-step DMA, then PCSS 0xBF (/VI). Status values seen by the
BIOS: 0x80 done, 0x76 not ready (the BIOS retries silently), others
printed as "read error: status=0xNN". The exact code table is OPEN
(derive from 0x00A2 SetWD2010StatusBit and the WD2010 error register).

Drive selection: `ANL P2, #EF` / `#DF` from bit 5 of byte 1. Both drives
hang on one cable; a drive not selected drives no status line.

Idle: no 8716 access; INTEN (P1.6) is a hand-over token Low only in the
0x005B-0x005F window (see PDMAC_8716.md section 7).

## 4. Timing the software relies on

- SOURCED (CCCP spec p. 4): between sectors the CCCP re-initialises the
  DMA in under 100 us; the model measures 88 us from T0 to LD0.
- SOURCED (WD2010-05 data sheet p. 95): buffer RE- every 1.2-2.0 us,
  data latched at its rise; the WD2010 fetches each byte one byte time
  ahead of the serialiser (the first data byte while the F8 mark goes
  out), which is what makes multi-sector writes line up (F-22).
- SOURCED (ROM 0x0701): MainInit pulses SMR- first; the WD2010 reset
  comes from MR-.
- Drive: 612 x 4 x 17 x 512 = 21.3 MB; the BIOS waits about 30 M cycles
  per HD command (WDSDP plus a restore) against 1 M for the floppy.
- Image limit (our board): 2047 cylinders (the WD2010's 11-bit cylinder
  register), 8 heads, 17 sectors (a 136-block cylinder buffer): 278,392
  blocks, about 142.5 MB. Raw images are the C900 types (at most 42.9 MB);
  larger ones must be a fixed VHD. A VHD past the limit is no drive.

## 5. How we learned it

- Schematic 68-000057 sheets 2-4 and the parts list (Pleban scan pp.
  184-195), read at 200-400 dpi; motherboard sheet 18 for CN9.
- CCCP spec 96-000016 (the strobe statements, T0/T1 roles, the <100 us
  re-arm). The U8 equations spec 96-000015 and the CCCP source listing
  75-000006 are not on file.
- The 8049 ROM, walked for every host access and the LBA divide; the
  WD2010-05 data sheet for Read/Write Sector flow (M bit, BRDY edge,
  CIP/BSY timing).
- Coherent `drv/wd.c` and `Ftwd8.c` (cylinder reads with one command),
  the BIOS submit/poll at 00:111E.
- The Go model and RTL boot Coherent from an HD image to login (359
  reads, 2 writes in a single-user boot).

## 6. Open questions

| Id | Question | Settles it |
|----|----------|-----------|
| O-23 | U8 product terms | fuse read of U8 |
| O-32 | OUTL strobe placement (ALE-timed or inside WR-) | logic analyser on U8 |
| F-16 | U8 power-up state | PAL16R6A-2CN data sheet |
| O-35 | U5 turnaround at a read's end | scope J4 DATA0 vs U8 pins 5/12 |
| O-38 | BCS- edge in Write Sector (ID match or write gate) | WD2010 flowchart at higher resolution |
| - | status code table | ROM walk of 0x00A2/0x0537/0x0784 |
| - | HS latch designator; WPCEN source | sheet 3 re-read |
