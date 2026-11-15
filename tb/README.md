# Testbenches

One directory per board, mirroring rtl/.  Conventions:

- `tb_<unit>.cpp`: Verilator vector replay, one record = one fabric clock,
  every output compared every clock, PASS/FAIL ladder printed.
- `tb_<unit>_timing.sv`: protocol and timing checks from the datasheet or
  schematic (`--timing` bench), each check numbered `[n]`.
- Every bench is built with `--x-initial unique`; RTL under test is linted
  with `-Wall` and no suppressions.
- Committed vectors (`tb/lance/vec`) come from the Go reference simulator
  (`tb/lance/gen/mkvec.sh`), never by hand.  No bench needs the simulator;
  benches that need Commodore ROMs take them as an argument.
  Benches here cover board glue and chip-to-chip wiring; chips verified in
  their home repo are not re-benched.

Add a `Makefile` in the board directory; `make tb` at the top runs every one.

## Benches

| Dir | What | Run |
|---|---|---|
| tb/clock | `tb_fantdiv`: crystal stand-in edge rates over 0.1 s (HDC Y101 10 MHz, keyboard 1 MHz, RTC 32.768 kHz) | `make -C tb/clock` |
| tb/expansion | `tb_ramcard`: the RAM card's segment decode and strobes, every size and segment; 15M against the Go card's 16M | `make -C tb/expansion` |
| tb/lance | `tb_lance`: the Am7990 LANCE card against Go-recorded scenarios (`vec/`, from `gen/mkvec.sh`): register rules, init block, ring walks, bus master cycles with random /WAIT, interrupts and the vector strap, FCS, address filter, internal loopback; bus events in order, frames on TX, memory at the end | `make -C tb/lance` |
| tb/mouse | `tb_mouse`: ps2_mouse_quad into the HR card's FN#7 on a 6 MHz ZCLK; 0x400/0x402 words after each move against the Go card; Gray steps at least 4800 clocks apart; reports dropped while the OSD is open | `make -C tb/mouse` |
| tb/hdc | `tb_hd_image`: hard disk geometry from raw image sizes and a fixed-VHD footer | `make -C tb/hdc` |
| tb/sdram | `sdram_ctrl` against `tb/common/sdram_model.sv` (timing-checking SDR model), both column geometries, random traffic with a random refresh hint | `make -C tb/sdram` |
| tb/lr_display | the LR card's SCC sockets; the LR card driven by a behavioural Z-bus master, pixels compared with a reference frame (`card`, needs `ROM1=<boot1.rom>`) | `make -C tb/lr_display [card ROM1=...]` |
| tb/host | `tb_disk_stream`: disk images streamed into BRAM (disk_stream) between an hps_io model and drive clients; `tb_uart_sel`: for each OSD Serial Port option the UART pins follow that SCC line and the other five idle High | `make -C tb/host` |
| tb/fdc | `tb_fdlseek`: one fd_layout reseeking with late grants against one that never reseeks; `tb_fdboard` (`board`, `fdwrite`, need `ROM1=<boot1.rom>`): the board's firmware reading and writing through the 8716 | `make -C tb/fdc` |
| tb/disk | `tb_disk`: the core behind the framework's hps_io and disk_stream, Main_MiSTer's side of the HPS bus (mount, SD status poll, 16 KB sector transfers) in the C++ driver, DDRAM model with random BUSY and latency; real images; `+inreset` mounts while the machine is held in reset | `make -C tb/disk`, then `obj_dir/tb_disk +rom=<boot0.rom> +rom1=<boot1.rom> +hd=/+fd1= [+inreset]` |
| tb/core | the whole machine (`c900_core`) on the real 48 MHz and 65.028 MHz clocks, boot0.rom through the boot ROM loader and boot1.rom through the ROM port, a behavioural RAM on the memory port (request-to-ack latency `+lat`, default 8; the SDRAM controller's idle read is 6) | `tb/core/gate.sh <rom_dir>` |

`tb/core/gate.sh <rom_dir>` (the C900 ROM dumps) is the whole-core gate: with no display card the
banner, self-tests and auto-boot on SCC U74 channel B and every DMA cycle
at the C900 Go simulator's Z8001 clocks (no disks, a synthetic hard disk,
a synthetic floppy: `tb/core/mkimg.py`); a keyboard key read as in the
simulator; with the LR card the screen through "MMU (U2) test: OK" and a
captured video frame; with the HR card the BIOS Z-bus transactions, the
0404H writes and the VRAM bitmap against Go `-board hr`.  The references in `tb/core/ref/` come from
`ref/goref/main.go.txt`; its traces have `tb_core` twins (`+trace`,
`+fdctrace`, `+hdctrace`, `+cbus`, `+dmalog`) for finding a divergence.
`tb_core` plusargs are listed at the top of `tb_core.sv`.

The gate's steps are listed in gate.sh's header. It runs on two cores
(`GATE_SLOTS`, `GATE_SLOTDIR` to share them between gates): the no-card
run forks the keyboard, floppy, hard disk and S1 runs at their first
difference (`+forks=`; the disk images mount then, at 9.0M and 19.2M
Z8001 clocks, before the BIOS probes the drive, not at power-on), and
each run stops once its check is complete (`+stopbytes=`; a child's
count includes the parent's SCC bytes, and its logs start with the
parent's lines). About 2.5 hours. `gate.sh -q` (about 10 minutes) keeps
the SCC to the banner, the HR Z-bus stream to 1.8M clocks against
`ref/go_hr_tx_1800k.md5` (cut from the full run's trace), the LR banner
and frame, and the short in-place-of-the-BIOS steps; a divergence after
1.8M clocks shows only in the full gate. `GATE_REUSE=1` rechecks the
last outputs without a run.
