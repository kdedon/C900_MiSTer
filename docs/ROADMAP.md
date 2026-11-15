# Roadmap

Milestones M0-M8 (scaffold, boot ROM, serial banner, LR console,
keyboard, floppy boot, hard disk boot, RTC, HR display) are done and
verified on the MiSTer; BUILD_STATUS.md has the log, EXPANSIONS.md the
option table, theory/README.md the OPEN questions about the hardware.

## Open work

- Floppy copy truncation (theory/FLOWS.md section 3): no RTL fault; a
  kernel race between sync and a growing write (INFERRED from the kernel
  source and a race test). Open: confirm on a real C900.
- SCC model: /INT gated by IEI and the acknowledge on the /AS-latched
  request (DECISIONS O-34); apply in k8000, re-vendor.
- One ST-506 media engine for both hard drives: the largest
  behaviour-neutral FPGA saving not taken (the 2026-11-05 space plan's
  change 3; changes 1, 2 and 4 are in main).
- 48 MHz memory-cycle strobe widths: needs a user decision (work queue
  item 12, 2026-11-07).
- Independent review of the single-step test change (sstep_check counts
  at the /AS fall and skips the aborted fetch) against SHS 3.10: the test
  changed, not the circuit (work queue item 13).
- Z8070 at 48 MHz: stores lose the first word while the APU is busy at
  the column strobe (DECISIONS D-BUS-14).
- tb/lance/gen/mkvec.sh and scripts/gen_lr_plas.sh regenerate the
  LANCE vectors and the LR PLA tables from the Go reference simulator
  and the PLA dumps (DECISIONS D-RTL-1); the build and the tests do not
  need them. tb/core/hrtests/shot
  scripts carry an absolute screenshot path.
- LANCE: a Coherent /dev/eth0 driver (theory/LANCE_CARD.md).
- Waiting on an owner of a real C900: HR stuck-arrow and login white-band
  reports, U11.9 continuity, "(hd)coherent" twice with the cable off
  (theory/README.md OPEN table).

From the 2026-11-14 code review, not applied:

- fd_head: track one zone and divide at a zone change (~90 ALMs and
  ~70 registers per drive); needs the fd benches and a boot.
- One cylinder buffer shared by both hard disks (60 M10K); reload
  latency on a drive switch; user call (DECISIONS D-IMG-5).
- lance_link ring counters 8 bits wide (~96 registers); needs Main to
  compare mod 256.
- c900_dispram 128 -> ~104 M10K: read-modify-write adds a clock to byte
  writes (HR and LC timing).
- fifo64 occupancy chain (~48 ALMs); the sample order is the 8716's,
  needs an equivalence bench.
- Whether the APU's 24 MHz and the HR card's 24M are one net (ck24_q
  and apu_ck24_q stay separate; Quartus merges them).
- C900_NO_* and C900_DISK_DEBUG variants are built by no file; lint
  each in `make lint-emu` or drop them. disk_dbg is outside `make lint`
  (unused-signal warnings).
- The k8000 chips are the bulk of the device (z8000_cpu ~5,000 ALMs,
  z8030_scc ~2,000 each x 3, z8036_cio ~1,600 each): a size review in
  the k8000 repo.
- Low-severity smells were not itemised; a later pass needs a fresh
  read.

## Known issues in the home repositories

- mc6845.vhd lacks a reset on `vs_hit_last`.
- PDMAC pattern review items O-3 and O-9 (PDMAC_PATTERN_REVIEW.md).
