# U54 FPLA "FPLA NEW" (motherboard memory decoder)

A Signetics 82S100 (PLS100) field-programmable logic array on
motherboard sheet 5 "Decoders and DRAM Timing". It is the memory
decoder: the two DRAM banks' row and column strobes, the boot ROM
select and one multiplexed DRAM address bit. Label: "C900 FPLA NEW U54".
It is fully dumped; everything below but the input-pin naming is read
from the dump.

Legend: SOURCED / INFERRED / OPEN as in PDMAC_8716.md. RTL:
`rtl/motherboard/c900_u54_fpla.sv` (the equations),
`rtl/motherboard/c900_dram.sv` (what the strobes drive).

## 1. The dump

SOURCED (dump file `C900 FPLA NEW U54 82S100 79fa1947.bin`, 65536
bytes): the complete truth table, byte V = outputs F7:0 for inputs
I15:0 = V. Output values are pin levels, so an active-Low strobe reads 1
when idle. The `PLA2EPROM` sibling file is a re-encoding for an EPROM
replacement, not the table. The 82S100 pinout (consistent across U54
and the two LR card PLAs): I0-I7 = pins 9, 8, 7, 6, 5, 4, 3, 2; I8-I15 =
27, 26, 25, 24, 23, 22, 21, 20; F0-F7 = 18, 17, 16, 15, 13, 12, 11, 10;
/OE 19 (grounded), FE 1 (programming, open).

## 2. Pins

Outputs, SOURCED (sheet 5 labels):

| F | Pin | Net | Drives |
|---|-----|-----|--------|
| F0 | 18 | _RAS0 | DRAM bank 0 row strobe (segments 0x08-0x0F) |
| F1 | 17 | _CAS0L | bank 0 column strobe, D7:0 (odd byte) |
| F2 | 16 | _CAS0H | bank 0 column strobe, D15:8 (even byte) |
| F3 | 15 | _RAS1 | bank 1 row strobe (segments 0x10-0x17) |
| F4 | 13 | _CAS1L | bank 1, D7:0 |
| F5 | 12 | _CAS1H | bank 1, D15:8 |
| F6 | 11 | _ROMCS | boot ROM pair U17/U18 select |
| F7 | 10 | MA8 | multiplexed DRAM address bit 8 |

Inputs. The roles are SOURCED from the dump's dependency structure (the
memory map as oracle); the net names are SOURCED from sheet 5 (Pleban
p. 157) except where marked.

| I | Pin | Net | Role in the equations |
|---|-----|-----|-----------------------|
| I0 | 9 | A18 (OPEN O-16) | MA8 column value |
| I1 | 8 | A17 | ROM select |
| I2 | 7 | A16 (OPEN O-16) | ROM select, MA8 row value |
| I3-I7 | 6-2 | A19-A23 | segment group |
| I8 | 27 | A0 | byte lane |
| I9 | 26 | _RFSH (ST = 0001 refresh) | row-strobe path |
| I10 | 25 | _BMREQ | row-strobe and ROM enable |
| I11 | 24 | BR/W | ROM enable (read only) |
| I12 | 23 | BB/W | byte/word for the column lanes |
| I13 | 22 | _CAS (U53 FF-A Q) | column timing |
| I14 | 21 | _NOMMU (/DMAEN) | row-strobe path |
| I15 | 20 | MUX (U53 FF-B /Q) | row/column select for MA8 |

SOURCED (sheet 5): U53 74S74 makes the two timing inputs. FF-A: D and
/CLR ride _BDS, so _CAS falls the instant the data strobe falls and
rises on the first CLK after _BDS rises; PRE = _SUP. FF-B: D = _BMREQ
clocked by CLK, /Q = MUX.

OPEN O-16: sheet 5 reads I0 = A18, I2 = A16; the MA8 mux (row = I2,
column = I0) would be more natural as {A17, A18}. The ROM select needs
A16 = A17 = 0 either way, and MA8 does not reach the core's SDRAM, so
nothing in the core depends on it. A meter on pins 7-9 settles it.

## 3. Equations

SOURCED (minimised from the dump; deassert form, the pin is High when
the expression is true):

```
_RAS0  = _BMREQ | _RFSH & _NOMMU & (!A19 | A20 | A21 | A22 | A23)
_RAS1  = _BMREQ | _RFSH & _NOMMU & ( A19 | !A20 | A21 | A22 | A23)
_CAS0L = A21 | !A19 | A20 | A22 | A23 | _CAS | (!A0 & BB/W)
_CAS0H = A21 | !A19 | A20 | A22 | A23 | _CAS | ( A0 & BB/W)
_CAS1L = A21 | !A20 | A22 | A19 | A23 | _CAS | (!A0 & BB/W)
_CAS1H = A21 | !A20 | A22 | A19 | A23 | _CAS | ( A0 & BB/W)
_ROMCS = A17 | A16 | A19 | A20 | A21 | A22 | A23 | _BMREQ | !BR/W
MA8    = MUX ? A16 : A18
```

Read as a memory map (held control bits at a normal read):

| Physical segment | Strobes | Meaning |
|------------------|---------|---------|
| 0x00, 0x04 | _ROMCS | boot ROM, 32 KB aliased in each (A18 unused; the 23128 pair ignores A15, so a 27256 pair would fill 64 KB in each) |
| 0x08-0x0F | _RAS0, _CAS0x | DRAM bank 0, 512 KB |
| 0x10-0x17 | _RAS1, _CAS1x | DRAM bank 1, 512 KB |
| 0x18 and up | none | expansion bus (RAM card, display card memory) |

Byte lanes: a word access (BB/W Low) strobes both columns; a byte access
strobes _CASxH at an even address (D15:8) and _CASxL at an odd one.

Row strobes: both banks' _RAS assert for any address while _RFSH is Low
(RAS-only refresh of both banks on the Z8001's refresh cycle) and while
_NOMMU is Low (DMA): the column strobes stay address-qualified, so only
the addressed bank drives or stores data. The ROM is a read-only select:
a write to segment 0 strobes nothing.

SOURCED (DECISIONS D-MEM-3): a 512K machine is bank 1 unfitted, no
jumper; its strobes still fire and the bus floats High.

## 4. How we learned it and what the core does

- The dump, read as a truth table; equations minimised and checked
  against all 65536 inputs (`tb/motherboard/tb_u54`). Validated against
  the BIOS's memory test (it counts segments 0x08 up until one fails)
  and the Coherent kernel map.
- Sheet 5 for the pin nets (Pleban p. 157, traced fully 2026-07).
- The core puts the DRAM and the boot ROM in SDRAM at the physical
  address and starts a read at the row strobe (or _ROMCS) and a write at
  the column strobe with R/W Low (`c900_dram.sv`; DECISIONS D-MEM-1,
  D-ROM-2). MA8 is not used: the core addresses SDRAM linearly.
- INVENTED, marked in DECISIONS D-MEM-4/D-MEM-8 (user 2026-11-13): the
  optional RAM card at segment 0x18 and up has its own decoder
  (`rtl/expansion/c900_ramcard.sv`); U54 is unchanged.

## 5. Open questions

| Id | Question | Settles it |
|----|----------|-----------|
| O-16 | I0/I2 = A18/A16 or A17/A18 | meter on U54 pins 7-9 |
| - | 82S100 propagation (50 ns max per datasheet) against the DRAM's RAS setup at turbo rates | board measurement; the core runs the strobes at fabric speed |
