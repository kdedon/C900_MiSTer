# C900_MiSTer

A MiSTer FPGA core for the Commodore 900: a Zilog Z8001 Unix workstation
(Coherent), 1984-85, never sold. Target: DE10-Nano (Cyclone V
5CSEBA6U23I7).

Status: boots Coherent from hard disk or floppy to a login on the
MiSTer, with the LR text card, the HR bitmap card and mouse, or headless
on the serial console; keyboard, RTC, second hard disk and the NON-STOCK
options (RAM card, LANCE, LC card, Z8070, 10/12/48 MHz CPU, serial mouse)
are built. The whole core also runs the boot ROM in Verilator
(`tb/core/gate.sh <rom_dir>`), cycle for cycle against the C900 Go
simulator. Open problems: docs/ROADMAP.md. Build log: docs/BUILD_STATUS.md.
How the machine works: docs/theory/README.md. What the 1985 software
does on this core and how to live with it: docs/KNOWN_ISSUES.md.

The rule: match the real hardware. A part without RTL is a stub with its
real port list and outputs held inactive, never invented behaviour. A chip
model gets no port its real chip lacks; chips run from their clock pins
(docs/DECISIONS.md D-CLK-3). Options the real machine never had are
labelled NON-STOCK, off by default, and leave the stock machine unchanged
when off.

## Layout

```
C900.sv             emu: MiSTer shell (hps_io, PLL, reset, video, UART, SDRAM)
C900.qpf/.qsf/.sdc  Quartus project; sources in files.qip
sys/                Template_MiSTer framework, byte-identical (do not edit)
rtl/c900_core.sv    the machine: backplane, bus resolution, cards
rtl/common/         fractional clock enable, sync, reset sync, ROM
rtl/motherboard/    CPU board: LS93, I/O decode, U54, DRAM, latch, RTC, 8716 PDMAC (pdmac/), mainboard
rtl/fdc/            floppy controller (CPU board sheets 13-16): 6508, 8723, drives
rtl/hdc/            WD1003-CMD hard disk card: 8049, U8, WD2010, WD10C20, drive
rtl/keyboard/       keyboard (6500/1) and the 311075 daughterboard
rtl/hr_display/     HR graphics card (top hr_card)
rtl/lr_display/     LR text card: CRTC (mc6845/), U13, U18, U22, CDR, pixel path, U31 SCC
rtl/expansion/      NON-STOCK: LANCE card, RAM card, Z8070 APU
rtl/host/           platform adapters: PS/2 keyboard, PS/2 and serial mouse adapters, disk images, LANCE link, HR video
rtl/sdram/          SDRAM controller
rtl/pll/, pll.*     user PLL, 48 MHz
rtl/pll_vid.v       video PLL, reprogrammed per card (HR 96 MHz, LR 65.028 MHz)
rtl/vendor/         synced external RTL + MANIFEST.txt (do not edit)
tb/                 per-board testbenches (tb/README.md)
lint/               Verilator waivers (rtl/vendor, moved chips)
scripts/            sync_vendor.sh, build.sh, make_boot_rom.sh
docs/               theory/ (how the C900 works), DECISIONS, EXPANSIONS, ROADMAP, BUILD_STATUS
releases/           release .rbf files
```

## Vendored RTL

External RTL is copied into `rtl/vendor/`; the Quartus project references
nothing outside the repo.

```
scripts/sync_vendor.sh             # from ../k8000/rtl and the upstream cores
SYNC_SYS=1 scripts/sync_vendor.sh  # also refresh sys/ from ../Template_MiSTer
```

The script copies each source at a commit (`HEAD`, or `K8000_REF`) with
`git archive` and records the commits in
`rtl/vendor/MANIFEST.txt`. Uncommitted changes in a source are reported,
not copied. It fetches (never pulls) and refuses a source behind its
upstream; `FORCE=1` overrides.

Sources: from k8000, the Z8001 CPU, Z8010 MMU, Z8030 SCC and Z8036
CIO. T65 and T48 are upstream VHDL (`rtl/vendor/t65`, `rtl/vendor/t48`):
Quartus compiles it; the Verilator benches netlist it at build time with
the pinned GHDL that `scripts/get_ghdl.sh` fetches into `tools/ghdl`
(`mk/ghdl.mk`).

## Firmware

The ROM images are not distributed; build the core's files from your C900
ROM dumps and copy them to `games/C900/` on the MiSTer (layout in
docs/DECISIONS.md D-ROM-5):

| File | Contents |
|---|---|
| `boot0.rom` | boot ROM: 32 KB (23128 pair) or 64 KB (27256 pair), U17 then U18 |
| `boot1.rom` | 6508, 8049, 6500/1 and LR character ROMs, 16 KB |
| `boot2.rom` | LANCE card boot ROM (`firmware/lance_bootrom`, `make`); optional |

```
scripts/make_boot_rom.sh <rom_dir> [out_dir] [u17_32k u18_32k]
```

`boot.rom` from earlier releases is not accepted: delete it.

## Disk images

Mount floppy images on S0/S1 and hard disk images on S2/S3 from the OSD.
Images stream on demand: the drive's current cylinder is read into block
RAM when the head moves and written back when it leaves or after 0.1 s
without writes; nothing is copied to DDR memory. The disk LED stays on
while writes are pending: wait for it to go out before ejecting or
switching off, or the last writes are lost (docs/DECISIONS.md D-IMG-5).

## Display card

OSD Display Card: LR, HR, None or LC 8563 (8568 colour card, 64 KB,
ports 0181H/0183H, ID C1 at 01FFH, polled, no interrupt). None leaves
the slot empty and the video output black. Change, then Reset.

## Memory

OSD Motherboard RAM: 1M (default) or 512K. Page 1 RAM card (non-stock):
None, 2M, 4M, 8M or 15M, from segment 18H up. The stock BIOS works with
2M on every display card. 4M, 8M and 15M with the LR card need the new
BIOS: the stock one takes the LR character RAM (37H) as memory.
Change, then Reset.

## CPU clock

OSD CPU Clock: 6 MHz (default) or the NON-STOCK 10, 12 or 48 MHz. Only
the CPU's clock moves; every other chip, I/O cycle and DMA runs at
stock timing, and the turbo logic stretches the CPU's cycles to meet
them (docs/DECISIONS.md D-CLK-6, 9, 12, 13, 14). Sources in
docs/theory/SYSTEM.md sec. 2. Change, then Reset.

| Speed | What it is |
|---|---|
| 6 MHz | stock: Y1 12 MHz crystal, divided by two; a Z8001A (6 MHz grade) on the board |
| 10 MHz | the fastest Z8000 Zilog sold: Z8001B, later Z0800110. A C900 was never built for it |
| 12 MHz | a Z8000 overclocked slightly past the 10 MHz part. Not a C900 configuration |
| 48 MHz | a fantasy accelerator: no real C900 could run it. Residuals in DECISIONS D-CLK-9, D-CLK-14 and ROADMAP |

## Serial port

OSD Serial Port picks the SCC line on the MiSTer UART (/dev/ttyS1 on the
HPS): U74 B (the console, default), U74 A, or a line of the LR card's
U31 or U36 (idle without the LR card). The other lines idle with nothing
attached. Use the UART menu for the connection and speed. The switch
takes effect at once; changing it while the line is busy may garble a
character. Example: SLIP on tty51 (U74 A) with the console on a display
card.

Page 1 Serial mouse (non-stock, off by default): a Mouse Systems
mouse, 1200 baud, on U74 A, from the MiSTer mouse. It takes U74 A's
input over from the MiSTer UART. Not offered with the HR card, which
has its own mouse port.

## Lint

```
make lint
```

Verilator `-Wall` over the core (top `c900_core`) and the platform
adapters. Our RTL has no suppressions; `lint/vendor.vlt` waives
`rtl/vendor/`, linted in its home repo.

## Build

```
scripts/build.sh
```

Full Quartus compile in the pinned Quartus Lite 17.0.2 Docker image, or
`quartus_sh` on PATH. Writes
`output_files/C900.rbf` and `output_files/summary.txt`. Results go in
docs/BUILD_STATUS.md.

## AI disclosure

This core was developed with AI assistance (Claude, by Anthropic): writing and reviewing the RTL, simulation benches and documentation, analysing the original software, and running the hardware tests. Hardware results were checked on a real DE10-Nano.

## Thanks

Thanks to the people whose help, hardware and research made this project possible:

- [Bo Zimmerman](https://www.zimmers.net/), who let me use his C900. Without
  that, my journey with this machine would never have started, and his
  documentation and help were invaluable in getting the project off the ground.
- [Michał Pleban](https://github.com/MichalPleban), for great stories of
  bootstrapping hard drives, his work modernizing Coherent, a wealth of useful
  documentation, and much more. This project is far more accurate and usable
  thanks to his contributions.
- The [Classic Computing forum](https://forum.classic-computing.de), for C900
  discussion, high-resolution photos, and previously missing chip information.

## Acknowledgements

This core could not exist without the following projects:

* The MiSTer project (Template_MiSTer framework, SDRAM controller by Sorgelig)
* T48, (c) 2004-2023 Arnim Laeuger
* T65, (c) 2002-2015 Daniel Wallner, Mike Johnson, Wolfgang Scherr, Morten Leikvoll
* VDC (8563/8568), from C128_MiSTer by Erik Scheffers
* MC6845, from BBC Micro for Altera DE1 (c) 2011 Mike Stirling, (c) 2022 David Banks
