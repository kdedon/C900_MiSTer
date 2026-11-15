# Keyboard: the 6500/1 controller and the 311075 interface board

The keyboard holds a MOS 6500/1 single-chip microcontroller (2 KB mask
ROM, firmware "C900KBD R2.3", 29 May 1984) scanning a 13 x 8 matrix and
sending PC XT scancodes over a six-wire cable. On the CPU board a
piggyback card, Commodore 311075 (one 74LS299, two 74LS74A, one
74LS125), assembles the bits into a byte for CIO U70 (Z8036 #1).
Sources: the keyboard schematic (Pleban scan p. 46), the 311075
schematic, the 6500/1 ROM (addresses below), the MOS 6500/1 data
sheet, the Z8000HR Hardware Specification 3.2, Coherent `rec/kb.c`,
and a photograph of the user's keyboard (Rockwell R6500/1EAB3 emulation
part with a 2716 EPROM).

Legend: SOURCED / INFERRED / OPEN as in PDMAC_8716.md. RTL:
`rtl/keyboard/c900_keyboard.sv` (matrix and cable), `mos6500_1_io.sv`
(the chip's ports, counter and IRQ), `kbdshifter.sv` (311075).

## 1. The keyboard unit

SOURCED (keyboard schematic p. 46; firmware scan at 0x09E3; DECISIONS
D-KBD-2): the 6500/1's XTLI takes a crystal labelled 2 MHz; Phase 2 =
XTLI / 2 = 1 MHz (6500/1 data sheet, Clock Oscillator). PB0-PB7 and
PC0-PC4 drive 13 columns, one Low at a time; PD0-PD7 sense 8 rows (a
pressed key pulls its row Low). Modifiers have their own inputs, Low
when pressed: LShift PA2, CapsLock PA4, RShift PA5, Ctrl PC6, LAlt PC7.
PA3 drives the CapsLock LED (toggled by the 0xBA code at 0x0AD2). The
cable: CLK = PA7, DATA = PA6, and PA0/PA1 read CLK and DATA back
through 7407 open-collector buffers.

The Z8000HR specification 3.2.2 says PD7 is data and PD6 the clock and
describes a Z8036 interlocked handshake on PC6/PC7; the firmware and
the 311075 board show otherwise (PA7/PA6; pattern-match interrupt and a
PC3 acknowledge). The specification describes an earlier design.

OPEN (D-KBD-1, user decision 2026-11-04): the crystal label on the
user's board is under solder; 2 MHz is the schematic's label. A
measured column strobe period (20 or 40 ms) settles it.

```
 6500/1: PB7:0, PC4:0 -> 13 columns -> matrix -> 8 rows -> PD7:0
         PA7 CLK, PA6 DATA -> cable -> 311075: U1 LS299 -> CIO U70 PA7:0 (byte), PC2 (bit 7)
         PA0/PA1 <- cable readback          U2b DAV -> PA7 pattern; PC3 KBDCLR clears
```

## 2. Firmware behaviour (ROM 0x0800-0x0FFF)

SOURCED (ROM listing). Reset 0x0800: delay, RAM test 0x00-0x3F with
0xAA/0x55, ROM checksum; on a clean checksum INIT_HW 0x088B sets the
port functions (PA interrupt/function 0x18, PC function 0x4E), clears
the ten key slots, sets the repeat counter to 0x2D, and the main loop
scans on the counter interrupt (latch 0x4E20 = 20 ms at 1 MHz). Each
scan (0x0951, 0x09E3) reads the 13 columns, compares with the previous
scan, debounces and encodes changes through the table at 0x0F8C
(index 8 x column + row), queues up to 10 events, and sends them.

Codes: PC XT make codes 0x01-0x62; a release sends the make code with
bit 7 set (kernel KEYUP 0x80). Auto-repeat: the last non-modifier key
repeats after 0x2D scans (0.9 s) and then every 4 scans (80 ms)
while held (0x0998-0x09B0). After a failed RAM/ROM test the firmware
runs a minimal loop (0x085E). At reset with PA1 reading High it sends
0xAB (0x0857); the second ID byte and the kernel's use of it are OPEN.

Scancode table (0x0F8C), row-major, 8 rows per column:

```
col 0: 4C 5E 49 02 0F 1E 53 41    col 7:  62 4B 40 09 16 25 39 49
col 1: 20 4A 01 03 10 1F 52 4F    col 8:  61 4C 41 0A 17 26 31 4E
col 2: 29 52 3B 04 11 20 2C 53    col 9:  60 4D 42 0B 18 27 32 5A
col 3: 56 53 3C 05 12 21 2D 53    col 10: 5F 49 43 0C 19 28 33 59
col 4: 57 51 3D 06 13 22 2E 5B    col 11: 54 48 44 0D 1A 20 34 58
col 5: 45 50 3E 07 14 23 2F 5C    col 12: 0E 47 55 2B 1B 1C 35 37
col 6: 46 4F 3F 08 15 24 30 5D
```

Codes above 0x53 are C900 keys without a PC equivalent (Coherent's
table: 0x55 Delete, 0x59 keypad '.', 0x5A keypad '/', 0x5E keypad
Enter, 0x5F-0x62 cursor up/left/right/down; the rest are function and
special keys, assigned in Coherent's C900 keymap). The host adapter's
mapping is in DECISIONS D-KBD-4/D-KBD-5.

## 3. The cable protocol

SOURCED (SERIAL_SEND_BYTE 0x08E6-0x0938): the keyboard waits until it
reads both cable lines High on PA0/PA1 (the host's hold-off, section
4), then pulls CLK Low with DATA High (the prelude edge), raises CLK,
and for each of the 8 bits, LSB first: puts the bit on DATA with CLK
High, pulls CLK Low (the shifter's edge), raises CLK and DATA. Each
half bit is a delay loop at 0x0AC6 of about 40 cycles: INFERRED bit
time about 0.1 ms, a byte about 1 ms. Interrupts are masked during a
byte.

SOURCED (311075 schematic; DECISIONS D-KBD-3; `kbdshifter.sv`): U1
LS299 shifts on the falling cable clock; the first edge after a clear
is the prelude, the next eight the byte, and the ninth completes it:
U2b sets DAV, the byte is presented (QB..QH = PA6..PA0, QA = PC2, the
last bit = bit 7, key up) and the register holds until CIO PC3
(KBDCLR) goes Low. While DAV is set U3b pulls KBDAT Low, and U2a
(/HLDKBCLK, bit 1 of a write to 0x204-0x207 on the U63 REN clock,
cleared by /KBRST) pulls KBCLK Low through U3a; since the keyboard
starts a byte only when both lines read High, it waits for the host
instead of losing the byte. The lines are open collector.

## 4. The host side (CIO U70)

SOURCED (Coherent `rec/kb.c`): port addresses PADATA 0x1B, PCDATA
0x1F (odd byte addresses, low lane). `kbinit`: Port A all inputs,
non-inverting, mode 0x1A (single buffered, interrupt on pattern match,
OR), no handshake; pattern "PA7 High" (PPR 0x80, PTR 0, PMR 0x80);
vector KBIRQ = 8; PC2 input, PC3 output. `kbintr`: read the code from
PA, the up/down bit from PC2 (`inb(PCDATA) & 0x04`), then `kbintend`
pulses PC3 Low then High (CLRKBD 0x70, SETKBD 0x78) to clear the
311075 register and DAV. The BIOS does the same by hand (`drv/video/
kb.c` 0x0C / 0xCC writes to the control port, "Clear keyboard",
"Enable keyboard").

So PA7 = DAV is the "byte ready" bit the pattern match fires on, PA6:0
carry code bits 6:0, PC2 carries bit 7. The Z8036 interlocked handshake
on PC6/PC7 that the specification names is not programmed.

Login path, SOURCED (boot gate): Ctrl-D is the four codes 29, 32, 160
(0x20 | 0x80), 157 (0x1D | 0x80): Ctrl make, D make, D break, Ctrl
break.

## 5. Timing the software relies on

- Key latency: 0-20 ms (one scan) plus about 1 ms for the byte.
- Repeat: 0.9 s delay, 80 ms period (0x2D and 4 scans of 20 ms).
- The host must acknowledge (PC3 pulse) before the next byte arrives;
  the hold-off makes the keyboard wait, so nothing is lost at any
  host speed.
- The 6500/1 edge detects on PA0/PA1 and its counter are the data
  sheet's; the firmware uses the counter in interval mode for the scan.

## 6. How we learned it

- The ROM, disassembled and walked (scan, encode, send, repeat).
- The keyboard schematic (Pleban p. 46) for the crystal, the matrix
  and the 7407 readback; the 311075 schematic for U1-U4.
- Coherent `rec/kb.c` and the BIOS keyboard init for the host side.
- The Z8000HR specification 3.2 as the earlier design (recorded, not
  followed where the firmware disagrees).
- The simulator and the core reach the Coherent login through this
  path with PS/2 input (DECISIONS D-KBD-4).

## 7. Open questions

| Question | Settles it |
|----------|-----------|
| crystal 2 MHz vs 1 MHz | measure a column strobe period |
| bit time on the cable | scope CLK |
| reset ID bytes (0xAB, second byte) and who reads them | ROM walk 0x0857-0x085D; kernel |
| the 311075 completion edge (positional count vs DAV gating) | scope DAV against CLK |
| cable wire colours to signals | continuity test |
