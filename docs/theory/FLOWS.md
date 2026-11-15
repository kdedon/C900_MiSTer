# Commodore 900: expected system flows

Step sequences with the ports and registers touched. Sources in brackets
as in [SYSTEM.md](SYSTEM.md); BIOS addresses are the shipped V1.0 ROM
(6/14/85) unless marked SRC (the decompiled BIOS source, which reproduces
V1.0 byte-exact at its tag 1.0). Kernel files are Coherent 0.7.3
src/sys/z8001. Tags SOURCED / INFERRED / OPEN / INVENTED as in SYSTEM.md.

## 1. Power-on and reset

1. U59 pulls _MRESET and _PRESET Low for 0.56 s; _PRESET forces _BAS and
   _BDS Low, resetting the SCC and CIOs; the MMU /CS is held Low, so it
   leaves reset in pass-through [SP 1, 6; DEC D-RST-2, D-RST-5].
2. The Z8001 loads FCW 0xC000 and PC 00:0038 from ROM 00:0002-0007. The
   same page is the ROM program status area: EPU 0x029E, privileged
   0x02A4, system call 0x02AA, segment trap 0x02B0, NMI 0x02BA, NVI
   0x02C0 [ROM 00:0000-0034].
3. 00:0038: SOUTB 0x00FC = 0x80 (MMU MSEN); SOUTB 0x11F8, 0x13F8, 0x14F8;
   LDCTL REFRESH 0x9E00; PSAP = 00:0000; clear all 64 descriptors
   (SOUTB 0x20F8 then 0x01F8 in a loop); SOUTB 0x00FC = 0xC0 (MSEN +
   TRNS) [ROM 00:0038-008A].
4. RAM probe at 00:0090, then LDIRB of 0x1016 bytes from ROM 0x6800 to
   physical 0x17E400 (BIOS RAM, logical segment 1; segment 0x3F = stack)
   [ROM 00:0100]. Every pass through reset rebuilds this area.
5. Console probe (section 2 step 3), final MMU map at 00:0D1C, banner
   "Commodore C900 diagnostics V1.0 (6/14/85)" at 00:0D4E, CALL 00:0326,
   and JP 00:0000 if it returns [ROM 00:01FE].

An S1 press repeats this with _PRESET High: the SCC and CIOs keep their
state, disks see no reset [SP 6; DEC D-RST-4].

## 2. BIOS boot

1. Memory test: 0x5555 / 0xAAAA through every DRAM segment with block
   instructions, then a per-segment tag pass against aliasing; RAM left
   zero; prints "Memory test: nnnnK OK" (size at 00:0B6C; a ROM quirk
   emits a NUL before each digit) or "RAM ERROR   BANK:CHIP= nn" [SRC
   memtest.c; ROM 0x0CB1]. The count stops at the first segment that
   fails, so RAM must be contiguous from 0x08 [DEC D-MEM-8].
2. Register tests: a table at 1:0C26 walks bits through "CIO1 (U78)",
   "CIO2 (U66)", "SCC  (U74)" registers, then "MMU  (U2) test": each
   segment 2-0x3E mapped onto a window at 0x0C and checked [SRC lceddt.c,
   porttest.c; ROM 0x436C]. The U78 name is the BIOS author's; the board
   designator is U70.
3. Console probe at 00:0CCC: write 0xFFFF then 0x0000 to 3E:0000 and read
   each back (a floating bus reads FFFF, so only RAM passes both): HR,
   NSPOFF = 1. Else the same at 37:0000: LR, NSPOFF = 2, cursor cleared
   at 1:0614. Neither: NSPOFF = 0, console on SCC U74 channel B. Flags
   1:17FF (HR), 1:1800 (LR), 1:041E (SCC initialised) steer putchar
   [ROM 00:0CCC; SRC rom.c]. The stock ROM has no card ID byte; only the
   extended BIOS probes 0x01FF for the LC card's 0xC1 (INVENTED, SRC
   conf.c lcprobe).
4. Video setup: LR, write 0 to 0x0418, fill 0x7D0 words of 0x0720 at
   3A:0000, load R0-R15 = 61 50 52 0F 19 06 19 19 02 0D 0B 0C 00 00 00 00
   through 0x0410/0x0412, then 0x0418 = 0x28 (video and blink on) [SRC
   diagdisp.s bvidchr]. HR: clear 3A:0000-3B:FFFF, OUTB 0x0404 = 0xFF
   [ROM 00:2120; SRC hrc.s].
5. "Automatic boot in progress" if the boot pointer 1:0006 is set, the
   serial override 1:0005 is 0 and the HR flag 1:0004 is 0 [ROM
   0x03BA-0x0444; SRC rom.c command()]:
   a. boot("(fd,1)coherent"), errors quiet.
   b. twice: boot("(hd)coherent"), then a delay of 0x4C4B40 counts;
      errors shown from the second pass ("TIMEOUT ERROR" only on the
      third attempt, after flag 1:000E clears).
   c. "Insert bootable floppy - hit any key twice when ready" or "Manual
      boot required ...", then the monitor "Commodore C900 monitor (type ?
      for commands)": (hd)file, (fd)file, l, m, FF<unit>, d, S n, P unit.
   Floppy drive 1 is the auto-boot floppy [DRIVE_NUMBERING; ROM 0x03BA].
   The stock ROM has no network boot; XMODEM, SLIP/TFTP and the LANCE ROM
   boot are extended-BIOS additions (INVENTED, SRC `#if ROMKB>32`).
6. boot() parses "(dev,unit)file" with a 12-byte device table at 1:05A2
   (hd handler 0x10CE, fd 0x10EC, shared load_block 0x11A6; unit numbers
   hd0 0, hd1 1, fd0 2, fd1 3) [ROM 0x1768]. The hd handler first issues
   WDSDP (section 4); fd needs no setup.
7. fsload reads the Coherent filesystem itself: inode 2, the directory
   entry "coherent", the l.out header (magic, LF_SEP|LF_32, M_Z8001), then
   text and data block by block through wdread [SRC boot.c]. The image
   belongs at the RAM base, where the command block also lives, so it is
   read one segment higher and LDIRB'd down [SRC boot.c comment].
8. Handoff: descriptors 0x30 (text) and 0x31 (data) are programmed, then
   a segmented JP to 30:<entry>. State: segmented, MMU translating, VI
   disabled, segment 1 still the BIOS RAM; word 1:0000 points at
   `struct romconf` (rom_bram, rom_eram in 1 KB clicks, rom_auto,
   rom_restart, rom_fdtype, rom_hdtype, rom_ctype = 1 for 6 MHz,
   has_hires) [SRC boot.c fsload; kernel commodore.c; md.s start].
   The 8716's completion /VI from the last polled read is still pending
   and is taken at the kernel's first `ei VI`; wdintr with no request is
   a guarded no-op [wd.c 424, 444; VI_TIMING_AUDIT 2.3].

## 3. Floppy read and write

Path: Z8001 -> 8716 U79 -> OMAD (PCSS, PCSD, BD7:0, /IREQ) -> 6508 U201
(ROM U203 at 0xE000) -> 8723 U204 (6508 addresses 0x4000-0x400F) -> M3470
read amplifier / write hybrid -> drive [SP 13-16; 8723 spec].

1. Host builds a 16-byte command block at 08:0010: +0 opcode (0x04
   format, 0x08 read, 0x0A write, 0x0F change block address, 0xE3 fill,
   0xDE goto), +1 unit (bit 5 = drive 1) | LBA[20:16], +2/+3 LBA, +4
   block count, +5 control (bit 5: interrupt per sector), +6..+8 DMA
   address, +0x0C status preset 0xFF [wd.c; SRC wd.c; 6508 ROM 0xE28A
   dispatch]. 2392 blocks per disk; buffers must be 512-aligned or the
   kernel bounces through 08:0400 [wd.c NFBLK].
2. OUTW 0x0500 = 1: the 8716 raises /IREQ to both controllers [BIOS
   00:1138; wd.c WDIO].
3. 6508 IRQ (0xE14D): waits host-ready on port 0x01 bit 7, sets 0x4002
   bit 2, PCSS 0x9F (IRQ_HIGH releases /IREQ); DMA-reads the block (PCSS
   0x7F reset, 0xFB LD2, 0xFD LD1, 0xFE LD0, 0xF7 FIFO_MOVE, bytes on
   PCSD at 0x4006). Status byte +0x0C not 0xFF: back to idle at 0xE0D7
   (this is how the other controller ignores the broadcast). Else the
   bytes go to zero page 0x28-0x2F and dispatch [6508 ROM].
4. Read (0xE2A6), per sector: write gate off, media-change check (seen
   as a write-protect transition; the drive has no change line), motor
   on (about 664 ms), seek, find the ID field (4 x FF sync, AM 0x08,
   cylinder, sector, checksum), wait sync, AM 0x07, 512 bytes through
   0x4005 (each byte strobes PCSD into the 8716 FIFO) with an XOR
   checksum; next sector advances the DMA address; PCSS 0xBF after each
   sector if +5 bit 5 is set [6508 ROM 0xE2A6-; 8723 spec]. Zones: tracks
   0-38 16 sectors, 39-52 15, 53-63 14, 64-79 13 [8723 GG bits; 6508 ROM].
5. Write (0xE32C): the mirror image, GCR encoded by the 8723, then a
   verify pass one revolution later (0xE3D3-0xE41F).
6. Completion (0xE197): status byte DMA-written to +0x0C (0x80 done; 0x70
   no disk, 0x73 media, 0x75 bad command, 0x76 changed media, 0x77 write
   protected, 0x91/0x93 header/AM errors), PCSS 0xFB, PCSS 0xBF VI_GND:
   the 8716 pulls /VI [6508 ROM; wd.c]. Kernel wdintr: status & 0x7F == 0
   is success; bdone, OUTW 0x0500 = 0, next request. The BIOS never
   enables VI: wdgo polls +0x0C with a timeout (0xF4240 counts, x30 for
   format), retries 0x76 up to ten times, then OUTW 0x0500 = 0 [SRC
   wd.c; BIOS 00:118E].

Floppy copy truncation (2026-11-09/11): after cp, sync, umount and
remount a copied file is shorter by whole blocks (72,928 -> 65,536); the
final inode write is missing while df counts every block. Found on the
MiSTer; not in the Verilator floppy bench (tb/fdc tb_fdboard).
Result (2026-11-10/11): no RTL fault. A debug core logging every FDC
command, floppy block and hps_io request (C900_FD_LOG, not kept) showed
every inode-block write decoded and committed with the bytes the kernel
sent, and in every short copy each inode write carried the short size:
the kernel never sent the final one. Race test, 48 MHz (6 MHz): with
/etc/update killed and no sync during cp, 0/24 (0/5) short; one sync
issued during cp, 5/24 (2/5) short, all with the sync meeting cp's last
writes. Mechanism, INFERRED from the kernel source (coh/fs1.c, fs3.c):
isync copies the in-core inode without locking it, then sleeps in bread
on the inode block behind the floppy queue (about 0.4 s per queued
write: write plus verify a revolution later); a write() that extends
i_size in that window is overwritten by the old snapshot and its IFMOD
cleared, so no later sync writes it. The core's floppy timing equals a
real board's (firmware steps and the 300 RPM platter; HPS latency has no
effect in tb_fdboard), so the same race should exist on real hardware.
OPEN: confirm on a real C900; per the project rule the 1985 software is
not patched.

## 4. Hard disk read and write

Path: Z8001 -> 8716 -> CN9 -> 8049 U10 (CCCP firmware) -> WD2010 U12 +
WD10C20 U101 -> ST-506 drive [WD1003-CMD board; CCCP].

1. Command block at 08:0000: opcodes 0x00 test ready, 0x01 restore, 0x03
   status, 0x05 check format, 0x06 format track, 0x08 read, 0x0A write,
   0x0C set drive parameters (WDSDP), 0x0F change block address, 0xE3
   drive diag, 0xE4 controller diag [wd.c 67-77]. (An older HDC note
   swapped 0x00 and 0x0C; wd.c and the BIOS use 0x0C for WDSDP.)
2. WDSDP first: zero 0x20 bytes at 08:0000, opcode 0x0C, DMA address
   08:0400 holding the 6-byte drive parameters (heads/cylinders/17
   sectors; BIOS default type 2 = 4 heads, 652 cylinders; Coherent 612 x
   4 x 17), doorbell, poll; non-zero status prints "controller/drive
   initialization failed" [SRC wd.c wdinit; BIOS 0x10CE -> 0x134A;
   kernel wdsetparam].
3. 8049 MainLoop 0x040: waits T0 (IREQ via the 74LS14), DMA-reads the
   status byte, PCSS 0x9F, DMA-reads the block to RAM 0x20, dispatches
   (JMPP @0x3F). Read 0x304: LBA to CHS by software division with the
   WDSDP values; a RESTORE first if flag 0x3C is clear; task file to the
   WD2010 (P1[2:0] register select); poll DRQ on P1.5; sector from the
   WD2010 buffer to host RAM through the 8716 (LD2 0xFB, LD1 0xFD, LD0,
   FIFO_MOVE 0xF7); status to +0x0C; PCSS 0xBF [8049 ROM; CCCP].
4. Drive select: P2.4/P2.5 from the unit bit; head select latched from
   the card bus under SDHLE- [WD1003-CMD; DEC D-HDC-3]. Completion and
   the kernel side as in section 3 step 6.

With no drive: the first read's RESTORE aborts on DRDY Low, status 0x84
(the BIOS hides 0x84, 0x92, 0x94 in quiet mode); a second read skips the
restore and the 8049 spins at 0x0333 waiting for BCS, so the BIOS
TIMEOUT fires. The core behaves the same [8049 ROM 0x0333; WD2010-05
pp.79-80; DEC O-22]. OPEN: a real C900 with the cable off, "(hd)coherent"
twice: expect the first quiet, the second TIMEOUT.

## 5. Keyboard: key to character

1. The 6500/1 scans 13 columns (PB0-7, PC0-4) into 8 rows (PD) every
   20 ms (Phase 2 = 1 MHz) and sends make and break codes serially on
   PA7 (clock) and PA6 (data), 8 bits, waiting for PA0/PA1 High as host
   feedback; PA3 is the Caps Lock LED [keyboard ROM r2.3 0x08E6, 0x08EF,
   0x09E3; DEC D-KBD-1/2]. Code table: [chips/KEYBOARD.md](chips/KEYBOARD.md).
2. The 311075 shifter (LS299 U4) completes a byte on the ninth falling
   cable clock: 7-bit code on CIO U70 PA6:0, bit 7 (break) on PC2, DAV
   flip-flop on PA7; HLDKBCLK holds the cable while DAV is set (one byte
   deep) [PLEB p.47; DEC D-KBD-3].
3. CIO U70 port A in pattern-match mode (PAMS 0x1A, pattern 0x80 / mask
   0x80, PAIV = 8, PACS 0xC0, MICR MIE, MCC port A enable); OUTB 0x0205 =
   0x02 enables the keyboard (bit 0 is IEEE REN, software copy needed);
   PC3 pulsed Low then High clears DAV [kb.c kbinit; SRC mbittest.s].
4. Interrupt, vector 8: u = PC2, c = PA & 0x7F; ktab[c]; shift, lock,
   Ctrl, Alt update kbsstate; ordinary break codes dropped; KDUP keys
   delivered twice; function keys followed by a state byte; Ctrl passes
   only KC-flagged keys; Alt sets bit 7; v0in(c) into the kv tty; kbintend
   clears IP and pulses PC3 [kb.c kbintr, kbintend].
5. The BIOS polls the same port for its prompts [SRC hrkey].

## 6. Interrupt service

1. The requester pulls /INT; IEI High and no IUS above it lets it drive
   /VI. The CPU finishes the instruction, aborts the next fetch and runs
   the acknowledge: ST 0111, /AS, five automatic waits, /DS; the chip with
   INTACK latched and IEI High drives its vector on AD7:0; the CPU takes
   it at mid-T3 [Z8036 TM Fig 20; Z8000 TM Jan 83 7.5; SYSTEM 6].
2. PSA (Coherent PSAP 30:0600, physical 08:0600): fixed traps at +0x00
   (EPU, privileged, SC, segment trap, NMI, NVI), VI at +0x38, 128
   4-byte VI entries from +0x40 (the Z8001 has 128, the Z8002 256); all
   default to vint [md.s start, psa].
3. vint: save R0-R13 and NSP, save the OS/ES descriptors, depth++, map
   the OS segment for the driver (vmaps_[id & 0xFE]), `ei VI`, call
   vecs_[id], and at depth 0 run stand() (timeouts, hrmouse) with VI
   enabled, `di VI`, restore, iret [md.s 577-657; VI_TIMING_AUDIT 1].
   Every driver ISR runs with VI enabled, protected only by its chip's IUS.
4. Dismissal: CIO IP survives the acknowledge, IUS blocks the chain; the
   clock ISR writes CT3CS = 0x24 (clear IP and IUS); SCC ISRs end with
   WR0 = 0x38 (Reset Highest IUS); wdintr writes 0x0500 = 0 [md.s clk;
   al.c; wd.c 444].
5. 100 Hz: CIO U70 C/T 3, PCLK 6 MHz, counting PCLK/2, TC 30000 (CLKVAL1;
   CLKVAL0 20000 if romconf says 4 MHz), CT3MS 0x80, CTIV 0, CT3CS 0x20
   then 0xC6, MICR 0x80, MCCR 0x90, CT3CS 0x06; measured exactly 100 Hz in
   the simulator [md.s lpclk 372-414]. The same routine sets CIO U66 port
   B for the printer (vector 0x70).

Findings on the MiSTer (2026-11-05..08), all bench-proven:
- A kernel panic "System trap type 11 at 8A00:106" in about 1 of 12-25
  cold loads was an acknowledge that read FFFF: identifier 0xFF indexes
  half-way into two PSA entries, PC lands in CPU-inhibited segment 0x0A,
  segment trap. Causes: (a) a DMA /DS after the CPU's I/O cycle reached
  the SCC or CIO that still held its select (the 8716 sends no /AS); the
  chips now take one access per /AS (INFERRED, DEC D-BUS-12); (b) the
  CIO model dropped IEO when a C/T hit terminal count during the
  acknowledge's /DS (live request instead of the /AS-latched one): a
  400 ns window per 8716 acknowledge at 100 Hz, about 1 in 25 boots; with
  the request latched at /AS, 0 panics in 100 loads (bench tb/iack
  tb_ctack; Z8036 AC table TdAS(IEO), TdIEI(IEO); UM0109 "no additional
  requests during an acknowledge"). The vendored CIO carries the fix.
  OPEN for the SCC model: /INT should need IEI High (UM0109 2.4.5.1) and
  its /DS-fall acknowledge uses the live request; neither caused a panic
  on hardware.
- The k8000 Z8001 uses the raw 8-bit identifier times two as the PSA
  offset, as MAME does. Fawcett 1982 p.83 says odd vectors are not used;
  the Jan 83 TM p.7-5 says they "cannot normally be used"; neither says
  what silicon does. OPEN: a real C900 or an erratum.

## 7. Video

LR text (BIOS and the kv driver): one word per cell at 3A:xxxx (physical
0x37), attribute high byte, character low, blank 0x0720; scroll by LDIR of
0x780 words from 3A:00A0 to 3A:0000; cursor by R14/R15 through
0x0410/0x0412; the CRTC values in section 2 step 4 give 80 x 25 with 14
scan lines; 16.257 MHz / 9 per character, 18.432 kHz, 49.82 Hz [SRC
diagdisp.s; LR p.47-51; DEC D-VID-1]. The attribute PLA U22 (dumped) and
U13 (undumped) are in [chips/LR_CARD_LOGIC.md](chips/LR_CARD_LOGIC.md).

HR bitmap:
1. Map logical 0x3A/0x3B to 0x3E/0x3F (kernel portst_ BMS descriptors),
   then OUTB 0x0414 = 0xFF (kernel v0load) or 0x0404 = 0xFF (BIOS): mono
   enable, intensity, bank bits (no effect) [HR_PROGRAMMING_SPEC 3;
   kernel hrtty; BIOS 00:2120]. No CRTC: the 82S105 SYN sequencer makes
   the timing (53.571 kHz, 59.99 Hz, 893 lines, 800 visible; measured
   2023-05-21).
2. Drawing is plain memory access, 128 bytes per row, bit 15 of the
   first word top-left, 1-5 waits per access; the kernel console is 85 x
   32 cells of 12 x 25 [hrtty; HR_PROGRAMMING_SPEC 4].
3. BEL is a visual bell: XOR of the top 50 scan lines twice (hrterm2.c
   bell(); getty's prompt starts with \7), so a white band flashes at
   every login prompt; this is 1985 software, not a card fault (RTL bench:
   12,800 bitmap cycles, clean afterwards) [getty.c; hrterm2.c].
4. Mouse: hrmouse() runs from stand() at every 100 Hz tick while enabled
   and an event manager is registered: IN 0x0400 and 0x0402, mask 0x3FF,
   integrate the signed 10-bit deltas, clamp to [0,1008) x [0,784), erase
   and redraw a 16 x 16 XOR sprite in software; buttons (bits 15:13)
   queue SM_MKEY to smgr then the desktop. No hardware cursor, no
   interrupt [MOUSE.md 6; driver/hr.c]. The card's counters are Amiga
   quadrature from J2 [HR FN#7; PLEB p.137].
5. OPEN, stuck arrow copies on the HR desktop (seen on the MiSTer): the
   smgr XOR/NXOR/NDST blits and lines read-modify-write the bitmap in
   separate instructions with the mouse drawn; a tick between them
   redraws the cursor and the write-back leaves a copy (bitblt.c 249-263,
   gline.c 78). A second path: CIOMSEOFF is honoured only for the current
   event manager (hr.c 644-651), so a right-button menu (dmgr holds the
   mouse) followed by "New Graphics" fills over a drawn cursor. Both are
   software races present on a real C900 (INFERRED from the source; the
   RTL card passes every read-modify-write pattern). Settling needs an
   owner's report from a real machine: does an arrow stick after a menu?

## 8. Serial console

1. The BIOS initialises SCC U74 channel B unconditionally through
   register pairs (odd ports 0x01 + 2n): WR9 0xC0 reset; WR4 0x4C (x16,
   2 stop bits, no parity); WR2 0x14; WR3 0xC0; WR5 0xE2; WR6/7 0; WR9 0;
   WR10 0; WR11 0x56 (BRG for Rx and Tx); WR12 0x11, WR13 0 (TC 17: 6 MHz
   / (2 x (17 + 2)) / 16 = 9868 baud, 9600 nominal); WR14 0x02 then 0x03;
   WR3 0xC1 (Rx on); WR5 0xEA (Tx on); WR15 0; WR0 0x10 twice; WR9 0x01;
   WR1 0 [SRC ramtest.s coninit, contab; DEC D-SER-2].
2. With NSPOFF = 0 putchar polls RR0 at 0x0101 (bit 2 Tx empty, bit 0 Rx
   available) and moves data at 0x0111; "\n" becomes "\r\n"; VI is
   disabled around the poll [SRC sio.c; ROM 00:016C, 00:0DB0].
3. The kernel prints its banner through the same polled path until init
   opens a tty (console.c, batflag). Init execs with "/drv/kv", so the
   login console is the video terminal; serial logins are getty on
   /dev/tty50-55 (/etc/ttys), tty50 = U74 channel B [md.s icode; al.c
   altty; /etc/ttys]. Older notes label 0x0101/0x0111 "channel A": the
   Z8030 selects channel A with AD5 = 1, so 0x010x/0x011x is channel B
   [Z8030 data sheet; DEC O-6].
4. On the MiSTer channel B is the HPS UART; channel A idles or carries the
   INVENTED serial mouse [DEC D-SER-3, D-SER-5].

## 9. Kernel takeover

1. start (md.s 303-365): SP = u_ area in segment 0x3F; NSPOFF/NSPSEG = 0;
   vecs_[0..127] = vret, vecs_[0] = clk; PSAP = psa; MMU SAR 0x30 with 16
   attribute bytes (command 0x0E) and SAR 0x31 with 15 limits (0x0D).
   Segment roles: 0x30 text, 0x31 data, 0x32 clist, 0x33 buffers,
   0x34-0x38 CPU-inhibited DMA windows, 0x39 WD mailbox, 0x3A/0x3B bitmap
   (user readable), 0x3C DDT, 0x3D ES, 0x3E OS overlay (driver window),
   0x3F stack and U area [md.s comments].
2. commodore(): copies romconf from 1:0000, corebot = rom_bram, coretop =
   rom_eram, arena and table pointers, BMS/BMS+1 bases [commodore.c].
3. lpclk (section 6 step 5), `ei VI`, main(): bufinit, cltinit, seginit,
   devinit (static drivers: ct, wd (major 2: hd0/hd1 and fd0/fd1 as units
   2/3), lp, al, kv), banner "Coherent (NNNK, nnnnn) Version 0.7.3",
   process(idle), eveinit, fsminit (root mount), copyright, scheduler
   [coh/main.c; con/lrcon.c; BIOS flow 28b]. The static driver list is
   per build: the LR install floppy kernel was decoded with alcon only.
4. wdload: setivec(0x80, wdintr), WDSDP to both hard drives; the floppy
   uses built-in parameters [wd.c 212-223].
5. icode execs /etc/init "/" "/drv/kv"; init runs loaddrv("/drv/kv") ->
   /etc/load -> load(2) -> puload maps the driver image into segment 0x3E
   and runs c_load: kbload (section 5 step 3) and v0load (section 7, the
   OUTB 0x0414 = 0xFF is the first HR-specific bus event after the second
   banner); then /etc/rc, /etc/ttys, getty [md.s 1303-1327; init.c].
6. Idle: `ei VI; HALT` at 30:0FC2; the 100 Hz tick keeps the system
   running [BIOS flow 32].
