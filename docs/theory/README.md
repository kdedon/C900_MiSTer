# C900 theory of operation

The historical record of the research behind this core: what the
Commodore 900 is, how its parts work together, and what was learned about
the custom parts no public documentation covered. Every statement carries
its source; guesses are marked INFERRED with their evidence; unknowns are
OPEN with what would settle them; this core's additions are INVENTED with
the approving DECISIONS row.

## Reading order

1. [SYSTEM.md](SYSTEM.md): block diagram, clock tree, CPU/MMU/bus, memory
   and I/O maps, interrupts, DMA, reset, connectors, cards, inventions.
2. [FLOWS.md](FLOWS.md): power-on, BIOS boot, floppy and hard disk
   transfers, keyboard, interrupt service, video, serial console, kernel
   takeover, as numbered steps with the ports touched.
3. The chip files, one per part that had no public documentation:

| File | Part | Board |
|---|---|---|
| [chips/PDMAC_8716.md](chips/PDMAC_8716.md) | MOS 8716 PDMAC U79 and its U80-U84 glue | CPU board |
| [chips/FDC_8723.md](chips/FDC_8723.md) | MOS 8723 floppy controller, the 6508 firmware, GCR format | CPU board floppy section |
| [chips/U54_FPLA.md](chips/U54_FPLA.md) | U54 82S100 address decode (dumped) | CPU board |
| [chips/LR_CARD_LOGIC.md](chips/LR_CARD_LOGIC.md) | U18 ZRSEL and U22 attribute PLAs (dumped), U13 PAL (inferred), the HD6545 use | LR text card |
| [chips/HR_CARD_LOGIC.md](chips/HR_CARD_LOGIC.md) | 82S105 SYN sequencer, memory PALs, U312 control latch, U755-U757 mouse PALs, the 0x04xx ports | HR bitmap card |
| [chips/HDC_CARD.md](chips/HDC_CARD.md) | 8049 CCCP firmware, U8 PAL, WD2010/WD10C20 use | WD1003-CMD card |
| [chips/KEYBOARD.md](chips/KEYBOARD.md) | 6500/1 firmware, scan matrix, code table, cable protocol, 311075 shifter | keyboard |

4. [LANCE_CARD.md](LANCE_CARD.md): the INVENTED Ethernet card, its boot
   ROM and the link to Main.

Other custom parts (address latches, the 8716 test rig, the 311075 piggyback board and the per-card PALs) and the file that covers each: [chips/INDEX_NOTES.md](chips/INDEX_NOTES.md).

Not described here, because public documentation exists: Z8001, Z8010,
Z8030, Z8036 (Zilog data sheets and technical manuals; the k8000 RTL
repository's docs), Z8070, Am7990 (AMD Technical Manual), WD2010 and
WD10C20 (Western Digital data sheets), HD6545, MSM58321, MOS 8568. SYSTEM
and the chip files say only how the C900 uses them.

## Sources legend

| Tag | Meaning |
|---|---|
| SHS | C900 System Hardware Specification, Rev 1.5, 1 Mar 1985 |
| SP n | CPU-board schematic, Rev C, sheet n |
| LR p.n, HR p.n, PLEB p.n | LR / HR card schematics and the Pleban board scan, page n |
| BIOS ss:oooo, SRC | boot ROM V1.0 address; the decompiled BIOS source (byte-exact at tag 1.0) |
| ROM + address | 6508 (U203), 8049 (U10), 6500/1 keyboard firmware disassemblies |
| dump | PLA/ROM dump file (U54, U18, U22, char ROM) |
| kernel file | Coherent 0.7.3 src/sys/z8001 source |
| measured | scope or logic-analyser capture on a real C900, or a MiSTer run |
| DEC D-x, O-n | [../DECISIONS.md](../DECISIONS.md) row |
| rtl/... | what this core does (C900_MiSTer) |

## Companion documents

- [../DECISIONS.md](../DECISIONS.md): every scaffold decision and the
  OPEN list; where a planning note and DECISIONS disagree, DECISIONS and
  the RTL win.
- [../EXPANSIONS.md](../EXPANSIONS.md): stock and NON-STOCK options and
  their build state.
- [../ROADMAP.md](../ROADMAP.md): open work.
- [../BUILD_STATUS.md](../BUILD_STATUS.md): timing rule and fits.

## OPEN questions, collected

| Item | What would settle it | Where |
|---|---|---|
| U11.9 (MMU /CS gate) is _MRESET not _PRESET | continuity check on a board | SYSTEM 3.1, DEC D-RST-5 |
| 6508 RESET source | trace the net (SP ISSUES 35) | SYSTEM 8, DEC O-4 |
| 8716 pin 3 (_IO_6) to U57 Y5 (0x0500, as firmware uses) or Y6 (0x0600, as drawn) | meter U79.3 against U57.9/.10 | SYSTEM 5, DEC O-17 |
| U54 inputs i0/i1/i2 = A18/A17/A16 order | meter U54 pins 7-9 | DEC O-16 |
| ST code and DIR wiring during 8716 DMA | capture or the 8716 data sheet | SYSTEM 3.4, DEC O-8 |
| Zilog peripherals: what a /DS without /AS does | real-chip test | SYSTEM 3.4, DEC D-BUS-12 |
| /WAIT during a CIO U66 acknowledge | scope on /WAIT during an acknowledge | SYSTEM 6 |
| Odd interrupt identifier on Z8001 silicon | a real C900 or an erratum | FLOWS 6 |
| SCC model: /INT gated by IEI, acknowledge on the latched request | apply in k8000, re-vendor | FLOWS 6 |
| CN13 APU header stuffed on production boards | board photo | SYSTEM 9, DEC O-10 |
| CN9 pin 32 "LD2" | HDC card trace | SYSTEM 9 |
| U205 head-matrix codes | 8723 spec or capture | SYSTEM 10, DEC O-14 |
| Y101 exact frequency; HR pixel clock | measurement | SYSTEM 2 |
| HR 0x0404/0x0406 read lane and mode bits | U755-U757 dumps | SYSTEM 5 |
| Floppy copy truncation: kernel sync race, no RTL fault (INFERRED) | the same copy-and-sync test on a real C900 | FLOWS 3 |
| HR stuck arrow copies | owner's report from a real machine | FLOWS 7 |
| Absent hard disk, second read | "(hd)coherent" twice on a real C900 with the cable off | FLOWS 4 |
| Undumped parts: LR U13, HR PALs (ZRSL, ZARB, ZMEMC, SYN, U755-U757), HDC U8, 8716 and 8723 internals | dumps | chip files |
