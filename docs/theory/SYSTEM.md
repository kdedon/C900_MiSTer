# Commodore 900: the machine

Theory of operation of the C900 motherboard and its cards, as the
research behind this core established it. Every statement carries its
source in brackets. Tags: SOURCED (a primary document, schematic, dump,
firmware address or measurement), INFERRED (a reasoned guess, with what
it rests on), OPEN (unknown; what would settle it), INVENTED (not on any
C900; this core's addition, with the approving DECISIONS row).

Source abbreviations:

| Tag | Source |
|---|---|
| SHS | C900 System Hardware Specification, F. Hughes, Rev 1.5, 1 Mar 1985 |
| SP n | Commodore 900 CPU-board schematic, sheet n (Z8000_Schematics.pdf, Rev C) |
| LR p.n, HR p.n | LR / HR card schematics in CBM900_special_chips.pdf, page n |
| PLEB p.n | Michal Pleban's board scan (scan Michal Pleban compleet.pdf), page n |
| BIOS ss:oooo | boot ROM address (U17/U18 pair, segment 0) |
| 8723 spec | MOS 8723 specification 315017 |
| CCCP | WD1003-CMD hard disk controller command protocol spec 96-000016 |
| DEC D-x / O-n | docs/DECISIONS.md row |
| RTL file | what this core does (C900_MiSTer rtl/) |

Chip files: [chips/](chips/) (PDMAC_8716, FDC_8723, U54_FPLA,
LR_CARD_LOGIC, HR_CARD_LOGIC, HDC_CARD, KEYBOARD). Flows: [FLOWS.md](FLOWS.md).

## 1. Block diagram

```
                         Y1 12 MHz -> U14 LS93 -> QA 6 MHz ZCLK, QB 3, QC 1.5, QD 750 kHz
   +------------------------------------------------------------------------+
   | CPU board                                                              |
   |  Z8001 U1 <-> Z8010 MMU U2 ----A23:A10----+                            |
   |   |  AD15:0, /AS /DS /MREQ R/W B/W N/S ST |                            |
   |   +--U3/U4 xcvr--> BAD15:0 ---------------+--> U54 FPLA: _ROMCS _RAS0/1 |
   |   |                      U56 latch A10:A8 |    U53 S74: _CAS, MUX      |
   |   |                      U57 LS138 /I-O0..7                            |
   |   |                                       |                            |
   |   |  0x00 ROM U17/U18     0x08-0x17 DRAM 41256 x 2 banks (512K each)    |
   |   |                                                                    |
   |   |  0x0000 CIO U70 keyboard, RTC U16 MSM58321, Centronics data        |
   |   |  0x0080 CIO U66 IEEE-488 (U67/U68), speaker, strobe/ack            |
   |   |  0x0100 SCC U74 ch B console, ch A                                 |
   |   |  0x0200 system latch U61-U64: single step, REN, keyboard shifter   |
   |   |  0x0500 8716 PDMAC U79 + U80-U83 address, U84 status: DMA master   |
   |   |         |            6508 U201 + 8723 U204: floppy, 2 drives       |
   |   |         +---CN9 ---> WD1003-CMD card: 8049 + WD2010 + WD10C20, U8  |
   |   |  CN11/CN12 display slot: LR (6545, U18 ZRSEL, U22, U13, SCC U31)   |
   |   |                        or HR (82S105 SYN, 128K bitmap, mouse PALs) |
   |   |  CN10 expansion, CN13 APU (Z8070, empty)                           |
   |   |  CN1/CN2 serial, CN3 speaker, CN4 IEEE-488, CN5 Centronics,        |
   |   |  keyboard cable (6500/1 in the keyboard, 311075 shifter U71)       |
   +------------------------------------------------------------------------+
```
SOURCED: SP 1-6, 10-16 (parts and connectors), SHS 2.1 and 3; card
sheets LR p.47-51, HR PLEB p.116-143. INVENTED cards (section 11) are
not drawn.

## 2. Clock tree

| Net | Rate | Made by | Consumers | Source |
|---|---|---|---|---|
| Y1 | 12 MHz | crystal oscillator, CPU board | U14 CKA | SP 2 |
| QA = ZCLK | 6 MHz | U14 LS93 (QA tied to CKB, R0 Low) | Z8001 and Z8010 CLK via U15 H3006A; CN9/CN10/CN11 _CLK; 8716 CLK; 8723 CLKIN; 8049 XTAL (over CN9) | SP 2; DEC D-CLK-2, D-CLK-4; 8723 spec 1.3.1 |
| CLK | 6 MHz, QA inverted by U13 LS04 | | SCC U74 PCLK, /RTxCA, /RTxCB; CIO U70 PCLK; U53 clock; CN11.59 to LR U31/U36 PCLK | schematics findings F-14 (special chips p.5, 18, 49, 51); DEC D-BUS-3, O-15 |
| QB | 3 MHz | U14 | unused on the sheet | SP 2 |
| QC = DCLK | 1.5 MHz | U14 | | SP 2 |
| QD = SNDCLK | 750 kHz | U14 | CIO U66 PCLK (its C/T 2 makes the speaker tone) | SP 2, 10; DEC D-CLK-2 |
| PH2 | 1.5 MHz = CLKIN/4 | inside the 8723, non-overlapping PH1/PH2 | 6508 Phi2, 8723 bus timing | 8723 spec 1.3.3; PLEB p.31 |
| Y101 | 10 MHz (INFERRED from the board photo; exact value needs a measurement) | WD1003-CMD crystal | WD10C20 data separator, WD2010 WCLK/RCLK | WD1003-CMD board photo; CLOCK_PLAN CLK-Q3 |
| keyboard crystal | 2 MHz (PLEB p.46 label; the part's own label is under solder); Phase 2 = 1 MHz | 6500/1 XTLI | key scan, 20 ms period | PLEB p.46; 6500/1 data sheet p.4; DEC D-KBD-1, O-25 |
| RTC crystal | 32.768 kHz, the MSM58321's standard crystal (INFERRED: part not read) | U16 | time of day | MSM58321 data sheet |
| LR U30 | 16.257 MHz; U24 LS163 divides by 9 to the 1.806 MHz character clock (80 x 25) | LR card | HD6545 CLK, shift register load | LR p.47-51; rtl/lr_display/lr_u13_pal.sv header |
| HR | 96 MHz VCO (U103 24 MHz region); mono pixel 96 MHz, colour 24 MHz; sync counter 1.5 MHz, 28 counts per line | HR card | 82S105 SYN sequencer, serialiser | HR_PROGRAMMING_SPEC 1 (line and frame rate measured on a real board 2023-05-21: 53.571 kHz, 59.99 Hz); pixel clock INFERRED from the timing |

The CPU has no wait-state generator and the clock tree has no gating: a
6 MHz CPU meets DRAM, ROM and Zilog peripheral timing by design
[DEC D-CLK-6 source column; SP 5].

Earlier planning notes gave CIO U70 750 kHz and the keyboard crystal
1 MHz; both are superseded (U70 at 6 MHz gives the kernel's exact 100 Hz
tick from C/T 3 TC 30000; the keyboard rate by the PLEB p.46 label and a
user decision 2026-11-04) [DEC D-CLK-2, O-25].

Core: one 48 MHz master clock; Y1 is a mod-4 phase counter and every chip
clock pin takes one-master-clock edge pulses from `rtl/clock/osc12.sv`,
`ls93.sv` and `fantdiv.sv` (Y101, keyboard, RTC) [DEC D-CLK-1..5].
Turbo CPU speeds move only the CPU's CLK pulses (INVENTED, D-CLK-6/9).

CPU speed grades, for the OSD CPU Clock option (README, CPU clock):

- 6 MHz, stock: Y1 / 2 (above) [SP 2]. The ROM's `romconf.rom_ctype`
  is "clock type: 0 = 4MHz, 1 = 6MHz" and the ROM sets 1 [SRC romconf.h,
  conf.c]. The 6 MHz grade is the Z8001A: Zilog's 1981 Data Book lists
  Z8001 4.0 MHz and Z8001A 6.0 MHz [1981 Zilog Microcomputer Components
  Data Book, Ordering Information, PDF p.134 (printed 131)]; a board
  inventoried for the schematic carries a Z8001APS, date code 8325
  [schematic findings, MODWIRES]. A September 1985 announcement spoke of
  a 10 MHz Z8001 (Commodore Microcomputers, LeBold, via Wikipedia
  "Commodore 900"); the hardware spec and the board say 6 MHz.
- 10 MHz, NON-STOCK: the fastest Z8000 Zilog made. "The maximum clock
  rate is 4 MHz for the Z8001 and Z8002, 6 MHz for the Z8001A and
  Z8002A, and 10 MHz for the Z8001B and Z8002B" [Fawcett, Z8000 Design
  Handbook 1982, PDF p.33 (printed 22)]; the 1988 Z8000 Family Data Book
  lists "4, 6 and 10 MHz clock rate" and orders the 10 MHz part as
  Z0800110PSC, "Z8001 Segmented CPU, 10.0 MHz" [1988 Data Book PDF p.131
  (printed 128); Ordering Information PDF p.562 (printed 559)]. Z8010,
  Z8030 and Z8036 exist in 10 MHz grades too [1988 Data Book Ordering
  Information]. INFERRED: no C900 was built with them; the board's DRAM,
  ROM and glue are timed for 6 MHz and the core stretches the CPU's
  cycles to stock timing instead [DEC D-CLK-6].
- 12 MHz, NON-STOCK: an overclock slightly past the 10 MHz grade; the CPU
  takes every ZCLK edge [DEC D-CLK-9]. Not a C900 configuration.
- 48 MHz, NON-STOCK, INVENTED: a CPU edge every master clock; nothing a
  real C900 could do. Known residuals: single-step counts twice, an
  aborted fetch waits one master clock more, memory-cycle strobe widths
  await a decision [DEC D-CLK-9, D-CLK-14; ROADMAP].

## 3. CPU, MMU and bus

### 3.1 Parts and cycle shape

- Z8001 U1, segmented, 6 MHz. Reset: FCW 0xC000 (segmented, system
  mode), PC 00:0038 from the ROM reset vector [SHS 2.1.1; BIOS 00:0000-0007].
- One Z8010 MMU U2. A8 and A9 bypass it, so a segment maps in 1 KB
  granules, not 256 bytes [SHS 2.1.1; DEC D-BUS-6]. SN6 reaches U2, all
  128 segments translate, 24-bit physical = 16 MB [DEC O-11; SHS 2.1.2].
  Physical address = A23:A10 from the MMU, A9:A0 from the U56 latch, or
  the U80-U83 word address while /DMAEN is Low [SP 5; DEC D-BUS-6].
- The MMU latches the address at the /AS rise; it answers only special
  I/O (ST 0011). /CS = latched AD1 AND _MRESET (U11): at power-on and
  during an S1 press /CS is Low, so the chip starts in pass-through
  (MSEN = 1) and the ROM is reachable [Z8010 data sheet pp.571-573; SP 5;
  DEC D-CLK-8, D-RST-5: the _MRESET term is INFERRED, pending a
  continuity check on U11.9; with _PRESET an S1 reset after a kernel ran
  read FFFF, with _MRESET 10 of 10 S1 presses rebooted].
- Status codes ST3:0: 0000 internal, 0001 refresh, 0010 I/O, 0011
  special I/O, 0100 segment trap ack, 0101 NMI ack, 0110 NVI ack, 0111
  VI ack, 1000 data, 1001 stack, 1010/1011/1110 EPU, 1100 program, 1101
  first instruction word, 1111 bus lock [Z8000 Data Book 1988 p.40].
  /MREQ is Low only in memory cycles; U54 takes it as _BMREQ, so I/O
  never reaches ROM or DRAM [SP 5; U54 dump].
- Refresh: the Z8001's own counter, enabled by the BIOS (`LDCTL REFRESH`
  with 0x9E00: one cycle per 120 ZCLKs) [BIOS 00:004C]. Refresh cycles
  carry ST 0001, U54 input i9 [SP 5].

### 3.2 Buffered bus and strobes

The CPU's AD15:0 reach the board as BAD15:0 through U3/U4 transceivers.
_BAS = _AS AND _PRESET, _BDS = _DS AND _PRESET (U11): during power-on
reset every buffered-bus chip sees /AS and /DS Low together, which is
the reset of the SCC and both CIOs (no reset pin) [SP 1; schematics
ARCHEOLOGY 2l; Z8030 TwRES 250 ns, Z8036 TwRES 170 ns]. The Z8001 and
Z8010 take the raw strobes.

### 3.3 Byte lanes

Even address = AD15:8, odd = AD7:0 (memory: DRAM _CASxH/_CASxL; ROM
U17 high byte, U18 low byte) [SP 4, 5; ROM CRCs c3aa7fc1 (U17), 0aa39272
(U18)]. A Z8001 byte write drives the byte on both halves of AD; a byte
read takes AD15:8 for an even port and AD7:0 for an odd one [Z8000 CPU
Technical Manual Jan 83 sec 9.4.3 p.9-6; Fawcett 1982 Fig 4.3]. The
8-bit Zilog peripherals sit on AD7:0, so firmware addresses them at odd
ports (SCC ch B control 0x0101, data 0x0111) [BIOS 00:016C, 00:0DB0;
al.c]. The Z8010 has pins AD15:8 only, so special-I/O command data rides
the high byte and the chip is selected by the low byte 0xFC [Z8010 data
sheet pp.559, 566; BIOS 00:0038-0084]. The Go simulator's "OUTB drives
D15:8, SOUTB D7:0" is that simulator's convention, not a hardware fact.

### 3.4 /WAIT, bus request, DMA

- /WAIT is a wire-AND driven only by the LR card's U13 (holds a CDR
  access to the card's CPU slot) and the HR card's arbitration PALs (1-5
  waits per bitmap access) [HR_PROGRAMMING_SPEC 4 from PLEB p.136; LR
  U13 undumped: INFERRED from the BIOS CDR timing, DEC D-CLK-6].
- /BUSREQ is the wire-AND of all masters; the grant chain is CPU /BUSAK
  -> 8716 /BAI -> /BAO -> CN11 (nothing stock) [SP 3; DEC D-BUS-5]. The
  8716 is the only stock DMA master. While it owns the bus /DMAEN is
  Low: U80-U83 drive A23:A1, U84 drives ST, /NOMMU Low, BB/W = word,
  U80 Q7 (DIR) drives BR/W; N/S and /AS are undriven [SP 3, 5; DEC O-8:
  the ST code during DMA (SP 1000 vs Design Review 0100) and the DIR to
  BR/W wire are OPEN]. The 8716 issues no /AS, so each DMA /DS reaches
  whichever chip latched its select at the CPU's last /AS; the Zilog
  parts take one access per /AS (INFERRED, user option B 2026-11-07,
  DEC D-BUS-12; the data books do not say what a /DS without /AS does;
  a real-chip test would settle it).
- DRAM: U54 makes _ROMCS, _RAS0, _RAS1 and the mux; U53 74S74 makes
  _CAS (falls with _BDS, rises at the next CLK rise, held High by _SUP)
  [SP 5; U54 dump checked over all 65536 inputs, tb/motherboard]. See
  [chips/U54_FPLA.md](chips/U54_FPLA.md).

## 4. Memory map (physical, 64 KB segments)

| Segments | Contents | Source |
|---|---|---|
| 0x00 | boot ROM U17/U18: 23128 pair = 32 KB, aliased twice (no A15); a 27256 pair fills 64 KB. _ROMCS = /MREQ Low, read, A23:A19 = 0, A17 = A16 = 0, so the pair also answers in 0x04 | U54 dump; SHS Fig 3-2; DEC D-MEM-3, D-ROM-5 |
| 0x01-0x07 | reserved (0x04 aliases the ROM) | SHS Fig 3-2; U54 dump |
| 0x08-0x0F | DRAM bank 0, _RAS0, 512 KB of 41256 on BAD with no buffer | U54 dump; SP 4 |
| 0x10-0x17 | DRAM bank 1, _RAS1; empty on a 512K board (strobes fire, bus floats High) | U54 dump; DEC D-MEM-3 |
| 0x18-0x36 | expansion RAM space, nothing stock decodes it | SHS Fig 3-2; DEC O-11 |
| 0x37 | LR card CDR: 2 x 2K x 8 SRAM U5 (char) / U6 (attribute), one word per cell | SHS 3.3.2; LR p.47-51; U18 ZRSEL dump |
| 0x38-0x3D | reserved | SHS |
| 0x3E-0x3F | HR card bitmap, 128 KB (16 x M5M4416), always at 0x3E0000 (the bank bits of 0x0404 select nothing on this card); 1024 x 800 uses 128 bytes per row, bit 15 of 3E:0000 is the top-left pixel; word writes ignore A0 | SHS 2.1.4.1, 3.3.1; HR_PROGRAMMING_SPEC 4; board photo |
| 0x40-0xFF | expansion space | SHS 2.1.2 |

Logical use: the BIOS keeps its work area at the top of the fitted DRAM
(1 MB: physical 0x17E400) through logical segments 1 and 0x3F, builds a
linear window in segments 2-0x17 and probes RAM upward until a segment
fails [BIOS 00:0038-0084 and the memory test; FLOWS 2]. The disk command
block lives at the base of RAM (physical 0x080000, DMA buffer at +0x400)
[Boot ROM Makefile CMDBLKPADDR]. Coherent maps logical 0x3A/0x3B to the
HR bitmap 0x3E/0x3F, and logical 0x3A to the LR CDR with the LR card
[kernel hrtty, kv drivers]. The BIOS picks its console by probing 0x3E
(HR) then 0x37 (LR); with neither it uses SCC U74 channel B [BIOS
AvidCHR 01:0004 / BvidCHR; FLOWS 2].

INVENTED: RAM card at 0x18 upward, skipping 0x37, 0x3E-0x3F and 0xFF
(section 11).

## 5. I/O port map (ST 0010, standard I/O)

Decode: U56 latches A10:A8 and IOPAGE (A15:A11 = 0) while /AS is Low;
U57 LS138, enabled by ST 0010 and IOPAGE, gives /I-O0../I-O7, one per
0x100 page; A7 goes to the Zilog chips' CS1 from the A bus [SP 5, 10-12;
PLEB p.146-157; DEC D-BUS-3]. Special I/O (ST 0011) never enables U57,
so the MMU window does not collide with CIO U66 at 0x0080-0x00FF.

| Address | Chip | Function | Source |
|---|---|---|---|
| 0x0000-0x007F (odd) | CIO U70 (/I-O0, CS1 = NOT A7) | Port A: keyboard KD0-6 + PA7 KD8 (make/break), pattern-match interrupt. Port B: Centronics data PB0-7, shared with RTC D0-D3 (PB0-3), READ PB4, WRITE PB5, ADWRITE PB6, STOP PB7. Port C: PC0 CBSY, PC1 TODSEL (RTC CS1 via U63), PC2 KD7, PC3 KBDCLR. C/T 3 = kernel 100 Hz | SHS 3.2.1, 3.6, 3.7; SP 10, 12; rtl/motherboard/c900_mainboard.sv |
| 0x0080-0x00FF (odd) | CIO U66 (/I-O0, CS1 = A7) | Port A: IEEE-488 D1-8 via U67 SN75160. Port B: PB0 SND (C/T 2 output, speaker), PB1 _CACK, PB2 SRQ, PB3 ATN, PB4 DAV, PB5 EOI, PB6 NDAC, PB7 NRFD via U68 SN75161. Port C: PC0 IFC, PC1 TE, PC2 DC, PC3 _CDS Centronics strobe | SHS 3.4, 3.6, 3.8; SP 10, 11 |
| 0x00F8 / 0x00FC (special I/O) | Z8010 U2 | command in AD15:8; 0x00FC mode, 0x01FC SAR, 0x02FC VTR, 0x03FC VSN, 0x04FC VOH, 0x05FC BCSR, 0x06FC ISN, 0x07FC IOH, 0x08FC descriptor base... | Z8010 data sheet; BIOS 00:0038-0084 and the MMU test |
| 0x0100-0x017F | SCC U74 (/I-O1, CS1 = NOT A7) | AD4:1 register, AD5 channel (1 = A): ch B control 0x0101, data 0x0111 (console); ch A 0x0121 / 0x0131. PCLK and /RTxC 6 MHz; TC 17 = 9868 baud (9600 nominal) | Z8030 data sheet; BIOS 00:016C, 00:0DB0, 00:101A-102C; al.c; DEC D-SER-3, O-6 |
| 0x0200-0x02FF | system latch U61-U64, U62 | any access with A1 set arms single step (STEP -> _NVI after the next instruction; cleared by the NVI ack or _MRESET); a write with A2 set latches D0 into IEEE REN and clocks the keyboard shifter enable (bit 1). Kernel: 0x0203 single step | SP 6; DEC D-SS-1; rtl/motherboard/c900_syslatch.sv |
| 0x0300-0x037F | LR SCC U31 (/I-O3, CS1 = NOT A7) | ch B 0x0300 (tty52), ch A 0x0320 (tty53) | LR p.49; al.c |
| 0x0380-0x03FF | LR SCC U36 (/I-O3, CS1 = A7) | ch B 0x0380, ch A 0x03A0; empty socket on the inventoried card | LR p.51; DEC D-SER-4 |
| 0x0410 / 0x0412 | LR HD6545 (via U18 ZRSEL) | CRTC address / data (RS = A1) | BIOS lkcrt; LR p.47; U18 dump |
| 0x0418 | LR control latch U23 | write: ENVID and link bits; cleared by _MRESET | BIOS; LR p.48 |
| 0x041C | LR _STAT | read decode with no data source | U18 dump |
| 0x0400 / 0x0402 | HR mouse PALs U755-U757 | read: X / Y count bits 9:0, bits 15:13 = buttons B1-B3 | HR_PROGRAMMING_SPEC 3, 6; PLEB p.137; MOUSE.md |
| 0x0404, 0x0414 | HR control latch U312 LS174 | write: bit 2 mono enable, bit 3 intensity 100/80 %, bits 1:0 bank (no effect); A4 not decoded; cleared by _MRESET. BIOS writes 0xFF at 00:2120, kernel hrtty writes 0x0414 | PLEB p.125-128; HR_PROGRAMMING_SPEC 3 |
| 0x0404 / 0x0406 read | HR | mode jumper JP3 bits 1:0 and position bits (INFERRED read path through the mouse PALs; U755-U757 undumped) | HR_PROGRAMMING_SPEC 3 |
| 0x0500 | 8716 PDMAC U79 _IO_6 | the disk doorbell: OUTW 0x0500,1 raises /IREQ to both disk controllers, OUTW 0x0500,0 drops it; the command block selects the unit. No other CPU-side register | BIOS 00:1138, 00:118E; kernel drv/wd.c WDIO; SP 3 wires U79.3 to Y6 (0x0600): OPEN O-17, meter U79.3 against U57.9/.10 |
| 0x0600 | (hard disk trigger in SHS) | unused by BIOS and kernel | SHS; see O-17 |
| 0x0700-0x071F | LANCE card (INVENTED) | RDP 0x0700, RAP 0x0702, station PROM 0x0710-0x0714, ROMA/ROMD 0x0718/0x071A | rtl/expansion/am7990_lance_card.sv; DEC D-USR-3 |
| 0x0181 / 0x0183 / 0x01FF | LC card (INVENTED) | 8568 address-status / data; ID 0xC1 | rtl/lc_display; DEC D-BUS-13 |

Not on the Z8001 I/O bus: the 6500/1 keyboard (serial cable to the 311075
shifter U71, then CIO U70 port A), the 8049 (commands through the
PDMAC's controller bus over CN9), the 6508/8723 (own bus, 0x4000-0x400F
from the 6508), the MSM58321 (CIO U70 ports B/C). See
[chips/KEYBOARD.md](chips/KEYBOARD.md), [chips/HDC_CARD.md](chips/HDC_CARD.md),
[chips/FDC_8723.md](chips/FDC_8723.md), [chips/PDMAC_8716.md](chips/PDMAC_8716.md).

Superseded addresses in older documents: CRTC at 0x0401/0x0403 (the
prototype spec; the board and BIOS use 0x0410/0x0412), a colour display at
0x0300 (SHS; the LR card's SCCs are there), the hard disk at 0x0600 (SHS;
firmware uses 0x0500), "CIO1 (U78)" in the BIOS test banner (the board
designator is U70).

## 6. Interrupts

Lines into the Z8001: /VI (vectored), /NVI, /NMI, plus the segment trap
from the MMU [SHS 3.13; SP 1].

| Line | Drivers | Source |
|---|---|---|
| /VI | wire-AND of CIO U70, SCC U74, CIO U66, 8716 U79, CN11 (LR U31/U36), CN13 | SP 1, 3, 6, 19, 20; DEC D-BUS-4 |
| /NVI | U62 /Q2 (single-step latch, sheet 6), pulled up (R1-R8 3.3K) to U1.13; CN11 pin 37 is an input from the slot | SP 1, 6; DEC D-BUS-15, D-SS-1 |
| /NMI | CN11 input; no on-board source found | SP 19; OPEN: a card or none |
| /SEGT | Z8010 | SP 1 |

Daisy chain, highest first: [APU on CN13 when fitted, a link joins IEI to
IEA when empty] -> CIO U70 -> SCC U74 -> CIO U66 -> 8716 -> CN11 pin 33
-> display card (LR: U31 then U36) -> CN11 end. CN11 pin 31 (chain top)
is undriven on the board [SHS 3.13 lists APU, keyboard CIO, RS-232 SCC,
IEEE CIO, DMA device; SP 19, 20; DEC D-BUS-4, D-BUS-14]. The floppy and
hard disk controllers are not chain members: they interrupt through the
8716 (PCSS command 0xBF VI_GND) [8716 sheet 3; PDMAC theory in
chips/PDMAC_8716.md]. The HR card has no interrupt source and no chain
pins [HR PLEB p.116-143]. An older planning note placing the LR card at the
top of the chain is superseded [DEC D-BUS-4].

Acknowledge: ST 0111 (VI), 0110 (NVI), 0101 (NMI). The chips latch INTACK
with /AS Low; the CPU inserts five automatic wait states, /DS falls in the
fourth, and the chip with INTACK latched and IEI High drives its vector on
AD7:0 while /DS is Low [Z8036 CIO Technical Manual Fig 20; Z8030 data
sheet AC table; Z8000 TM Jan 83 7.5]. The Z8001 uses the 8-bit identifier
times two as the PSA offset; neither Zilog manual says what an odd
identifier does on silicon, and the kernel masks it with 0xFE [Z8000 TM
Jan 83 p.7-5; Fawcett 1982 p.83; md.s vint; DEC O-A in FLOWS 6]. OPEN:
whether sheet-18 logic stretches /WAIT for a CIO U66 acknowledge (its PCLK
is 750 kHz); the BIOS flow notes say yes, DEC D-CLK-6 lists only the card
PALs as /WAIT drivers; settle with a scope on /WAIT during an acknowledge.

Vectors as Coherent installs them (all SOURCED from the kernel source):

| Vector | Device | Programmed by |
|---|---|---|
| 0x00 | CIO U70 C/T 3, 100 Hz clock (TC 30000 at 6 MHz PCLK, counts PCLK/2) | md.s lpclk; CTIV 0 |
| 0x08 | CIO U70 port A pattern match on PA7 (keyboard DAV) | rec/kb.c KBIRQ |
| 0x10-0x1E | SCC U74, status affects vector; LR SCCs likewise in their al.c slots | drv/al.c WR2 = 0x10 |
| 0x70 | CIO U66 port B (Centronics /ACK) | lp.c LPIRQ; md.s |
| 0x80 | 8716 (both disks; one wd.c driver) | drv/wd.c WDVEC 0x80; rtl/motherboard/pdmac/pdmac.sv VECTOR |
| 0x88 | LANCE (INVENTED) | rtl/expansion/am7990_lance_card.sv |

An older BIOS flow document gave the 8716 vector as decimal 80 (0x50);
the kernel source and the firmware say 0x80.

## 7. DMA

One 8716 PDMAC U79 with U80-U83 address counters and U84 status driver
(SP 3 "DMA logic"). Its controller bus (OMAD: BD7:0, PCSS, PCSD, /IREQ)
runs to the floppy section on the board (6508 + 8723, SP 13-16) and over
CN9 (34-pin ribbon) to the WD1003-CMD card [SP 3, 13; PLEB p.146]. One
broadcast /IREQ reaches the 6508 /IRQ and the 8049 /INT; there is no
arbitration wire: the kernel's single-driver mutex (wd.c wdu_active)
serialises the two, and the controller whose command block status byte
is not 0xFF goes back to idle [SHS 3.11; 6508 firmware 0xE0D7; 8049
firmware MainLoop 0x040]. Command blocks are at physical 08:0000 (hard
disk), 08:0010 (floppy), 08:0020 (tape, never built), 16 bytes each, DMA
buffer at 08:0400 [SHS 3.11 Fig 3-3; wd.c; Boot ROM Makefile]. The 8716
asserts /BUSREQ from its FIFO comparator, runs word cycles with ST 1000
and /NOMMU Low (physical addresses, no MMU), and releases at FIFO
satisfied [8716 sheet 3; DEC D-BUS-5, D-BUS-6, O-8]. Details:
[chips/PDMAC_8716.md](chips/PDMAC_8716.md), FLOWS 3 and 4.

## 8. Reset

| Net | Driven by | Resets | Source |
|---|---|---|---|
| _MRESET | U59 NE556 section 2 at power-on (0.56 s stretch), or section 1 fired once by S1 through C86/R22 (OUT1 High 1.1 x 510K x 1 uF = 0.561 s), ORed in U60 | Z8001 U1.16, Z8010 U2.5, 8716 U79.32, CN9.30 (8049, WD2010 MR, U8), 8723 U204.36, single-step U11.4 / REN U64.13, keyboard shifter U71.9, CN11.5, CN13; LR U9 /RESET and U23; HR U312; MMU /CS gate (INFERRED, D-RST-5) | SP 6; DEC D-RST-2, D-RST-4 |
| _PRESET | U59 section 2 only (power-on) | U11.1/.13: _BAS = _AS AND _PRESET, _BDS = _DS AND _PRESET, so the SCC and CIOs see /AS and /DS Low together (their reset); CN11.3, unused by cards | SP 1, 6; schematics ARCHEOLOGY 2l (trace wins over the 1984 Design Review text) |
| 6508 RESET | no driver on the sheet (SP ISSUES 35); the core uses _MRESET | | OPEN O-4: trace the net |

S1 therefore restarts the CPU, MMU, 8716, both disk controllers and the
cards while the SCC and CIOs keep their registers; a kernel's SCC baud
survives a reset [DEC D-RST-4].

## 9. Expansion connectors

| Connector | Pins | Carries | Source |
|---|---|---|---|
| CN9 | 34 | OMAD to the hard disk card: DMAD0-7 (2-16), _PCSS 18, _PCSD 20, IREQ 22, _CLK 26, _EST 28, -12 V 29, _MRESET 30, pin 32 "LD2" (OPEN O-33: purpose), INTEN 34 | PLEB p.146; SP 3 |
| CN10 | 64 | BAD15:0, ST3:0, _BAS, _BDS, BR/W, BB/W, _CLK, /STOP (pin 57 with CN13) | SP 19 |
| CN11 | 64 | control: _BAS, _BDS, BR/W, _VI, _VIACK, IEI (31, undriven), IEO from the 8716 (33), _NVI 37, _MRESET 5, _PRESET 3, _CLK 59, _I-O3, _I-O4, /WAIT, /BUSREQ, /BAO, A7, _BALLST 57 (no driver) | SP 19; DEC D-BUS-13..15 |
| CN12 | | A23:A10 (MMU outputs through U6/U7), /SUP | SP 19; DEC O-11 |
| CN13 | 60 | APU header: the CPU's own AD, ST, strobes, SN, N/S, ZCLK, CLK_12, /STOP, _VI, IEI/IEA, _MRESET; link and pull-up for the chain when empty | SP 20 (Rev C); DEC O-10: whether production boards stuff it |

Only /I-O3 and /I-O4 of the seven page strobes reach the display slot, so
a display card decodes 0x0300-0x04FF [SP 19]. SHS 4.4 defines no card
pinout ("expansion cards defined at a later date"); the SHS I/O map
reserves 0x0180 for an 8563 colour display and 0x0700 for a LAN
controller, neither of which Commodore built [SHS 3.12].

## 10. The cards and peripherals

| Unit | Board and parts | How the CPU sees it | Detection | Source |
|---|---|---|---|---|
| LR text card | 311064: HD6545 U9, 2 x 2K x 8 CDR U5/U6, char ROM U2 (4 KB, dumped), LS166 shifter U1, PAL U13 (undumped), 82S100 U18 ZRSEL and U22 attribute (dumped), U30 16.257 MHz, U24 LS163, SCC U31, SCC socket U36, DB9 video CN2, DB25 serial CN3/CN4 | CDR at segment 0x37 (/WAIT to the fetch slot); 0x0410/0x0412 CRTC, 0x0418 control, SCCs 0x0300-0x03FF; 80 x 25, 720 x 350, 18.432 kHz, 49.82 Hz | VRAM write/read at 0x37 (BIOS 00:0CCC) | LR p.47-51; DEC D-VID-1; [chips/LR_CARD_LOGIC.md](chips/LR_CARD_LOGIC.md) |
| HR bitmap card | ECL shifter (FN#1), memory control PALs ZRSL/ZARB/ZMEMC and 82S105 SYN (FN#2), 16 x M5M4416 (FN#3/4), control latch U312 (FN#3), mouse PALs U755-U757 (FN#7), J2 mouse DB9, J3 RGBI footprint, JP1-JP3 | bitmap 0x3E-0x3F with 1-5 waits; 0x0400/0x0402 mouse, 0x0404/0x0414 control; no CRTC, no interrupt | VRAM write/read at 0x3E (BIOS 00:0CCC) | HR PLEB p.116-143; HR_PROGRAMMING_SPEC; [chips/HR_CARD_LOGIC.md](chips/HR_CARD_LOGIC.md) |
| Hard disk card | WD1003-CMD (68-000057): 8049 U10 (mask ROM 29-000085-00), WD2010-05 U12, WD10C20 U101, PAL16R6 U8 (undumped), LS245 U5, RS-422 3486/3487, Y101, J1-J3 ST-506, J4 host | no registers; command block 08:0000 and the 0x0500 doorbell; completion by vector 0x80; drives hd0/hd1, boot ROM dparam[] 10/10/20/42.9 MB; images up to 2047 x 8 x 17 (142.5 MB, a fixed VHD above 42.9 MB) | the probe's first command (WDSDP) status | WD1003-CMD board; CCCP; [chips/HDC_CARD.md](chips/HDC_CARD.md) |
| Floppy section | on the CPU board (SP 13-16): 6508 U201, ROM U203 (8 KB), 8723 U204, LS245 U202, LS45 U205 head matrix (OPEN O-14: code to drive/side), two 5.25" drives, GCR, 4 zones of 16/15/14/13 sectors, 2392 blocks | command block 08:0010 and the doorbell; completion by vector 0x80; fd0/fd1 are wd units 2/3 | the probe's first read of (fd,1) | 8723 spec; 6508 firmware; [chips/FDC_8723.md](chips/FDC_8723.md) |
| Keyboard | 6500/1 in the keyboard, 13 x 8 matrix, 2 MHz crystal, J1-J3; 6-wire cable to the 311075 shifter (LS299 U4, LS74s, LS125) over the CIO socket | CIO U70 port A: 7-bit code + PC2 make/break, PA7 DAV, PC3 clear; enable bit at 0x0205 | none; the BIOS reads it | PLEB p.46-47; keyboard ROM r2.3; [chips/KEYBOARD.md](chips/KEYBOARD.md) |
| Serial | SCC U74 behind MC1488/1489 to CN1/CN2; LR U31/U36 add four lines | 0x0100 (ch B, console), 0x0120 (ch A); 9868 baud from TC 17 | the BIOS initialises it unconditionally | SP 11; al.c; DEC O-6 |
| Printer | Centronics CN5 through 7407s: data U70 PB, BUSY U70 PC0, /ACK U66 PB1, strobe U66 PC3 | CIO ports; vector 0x70 | | SP 10, 11; lp.c |
| IEEE-488 | U67 SN75160, U68 SN75161 to CN4; REN from the system latch | CIO U66 ports A-C | no Coherent driver | SP 10; SHS 3.4 |
| Speaker | U66 C/T 2 on PB0 through U69 7407s to CN3 | PCLK 750 kHz: lowest tone 5.7 Hz | Coherent never sounds it | SP 10; SHS 3.8 |
| RTC | MSM58321 U16, D0-D3 on U70 PB0-3, READ/WRITE/ADWRITE/STOP on PB4-7, CS1 from PC1 via U63; battery backed | bit-banged through CIO U70 | | SP 12; SHS 3.9 |
| Switches | power switch, reset S1; no DIP switches | | | SHS 4.2; SP 6 |

## 11. INVENTED: additions in the MiSTer core

None of these exist on a C900. Each is an OSD option, off by default,
held in reset with outputs masked when off, so the stock machine is
unchanged [DEC D-OSD-3, user rule].

- LANCE Ethernet card (Am7990) on CN11 at 0x0700 (RDP), 0x0702 (RAP),
  station PROM 0x0710-0x0714, boot ROM window 0x0718/0x071A; last in
  the chain, vector 0x88; bus master behind the 8716 (/BAO), holds /MREQ
  for the grant. Approved: DEC D-USR-3 (user 2026-11-01, address),
  D-ROM-4/5 (user 2026-11-14, ROM), D-MEM-9 (2026-11-12). Built from the
  AMD Technical Manual, no third-party core. `rtl/expansion/am7990*.sv`,
  `rtl/host/lance_link.sv`; registers, boot ROM and host link in
  [LANCE_CARD.md](LANCE_CARD.md).
- RAM card on CN10/CN12 from segment 0x18 upward, skipping 0x37,
  0x3E-0x3F and 0xFF: 2M (to 0x36, safe with the stock BIOS), 4M, 8M,
  15M. Strobe timing copied from the motherboard banks (INFERRED). DEC
  D-MEM-8 (user 2026-11-13). `rtl/expansion/c900_ramcard.sv`.
- LC colour character card in the display slot: MOS 8568 at 0x0181/0x0183,
  ID byte 0xC1 at 0x01FF, 64 KB RAM shared with the HR bitmap block RAM,
  INTR on CN11 _NVI. The SHS reserved 0x0180 for an 8563 display but no
  board existed. DEC D-OSD-4, D-BUS-13/15, D-VID-5, D-MEM-8 (user
  2026-11-07..12). `rtl/lc_display/`.
- Z8070 APU on CN13: the CPU's own pins, /BSY to /STOP, chain top. Whether
  CN13 is stuffed on production boards is OPEN (O-10); Coherent has no
  FPU support. DEC D-BUS-14 (2026-11-08). `rtl/expansion/z8070_epu.sv`.
- CPU clock 10/12/48 MHz: only the CPU's CLK pulses move; I/O-class
  cycles, grants and the Zilog recovery times stay at stock timing, and
  a turbo block drives /WAIT as a card would. DEC D-CLK-6, 9, 12, 13
  (user 2026-11-02, 2026-11-12). `rtl/motherboard/c900_turbo.sv`.
- Serial mouse: a Mouse Systems 5-byte 1200 baud mouse on U74 channel A,
  from the MiSTer PS/2 mouse; forced off with the HR card. DEC D-SER-5
  (user 2026-11-15). `rtl/host/ps2_mouse_msys.sv`.
- Host conveniences: RTC seeded from HPS time while _MRESET is Low (DEC
  D-RTC-2); U74 channel B wired to the HPS UART (D-SER-3); LR U36 always
  fitted (D-SER-4); disks streamed cylinder by cylinder through BRAM
  (D-IMG-5); boot ROM pair from `boot0.rom`, 32 or 64 KB (D-ROM-5); no
  printer in the UI (D-PRN-1).
