# Build status

## Timing rule

scripts/build.sh runs scripts/timing_check.sh on C900.sta.summary. Every
clock needs setup, hold, recovery and removal slack >= 0. The one exception
is pll_hdmi setup (framework scaler, constrained at 148.5 MHz), allowed down
to -0.250 ns: its ascal o_vcpt_pre3 -> o_vtotal compare path misses by
-0.165 ns even in ao486, and sys/ is not ours to change.

## Latest fit

2026-11-16, commit 93672de (Quartus Lite 17.0.2, no seed): 39,163 of
41,910 ALMs, 538 of 553 RAM blocks, HDMI setup +0.043 ns, timing_check
OK. RAM placement and the dropped shift-register experiment: DECISIONS
D-BLD-8, D-BLD-9. A release rebuilds until a fit passes timing_check
(D-BLD-9); seeds are not committed.

## Fit history

Fits that changed the device budget. Commits before 2026-11-14 were
squashed when the RTL moved into this repo and have no hash here.

| date | commit | what | ALMs | RAM blocks | pll_hdmi setup |
|---|---|---|---|---|---|
| 2026-11-16 | 93672de | LANCE ROM window 12 M10K, MLAB queues, 32K format index | 39,163 | 538 | +0.043 |
| 2026-11-14 | - | review savings (t48_wdc RAM in MLAB, 8568 row latches in M10K) | 40,738 | 520 | +0.256 |
| 2026-11-14 | - | RTL native, LANCE boot ROM window | 41,566 | 525 | +0.092 |
| 2026-11-13 | - | LANCE host link, 64 KB boot ROM in SDRAM | 40,886 | 507 | +0.075 |
| 2026-11-12 | - | LANCE card integrated | 40,851 | 538 | +0.301 |
| 2026-11-04 | - | RAM card, mouse, serial ports | 35,245 | 298 | +0.205 |
| 2026-11-03 | - | disks survive a machine reset; headless | 32,755 | 298 | +0.714 |
| 2026-11-03 | - | one build, both display cards from the OSD | 32,680 | 298 | +0.373 |
| 2026-11-02 | - | VHDL T48/T65, one fd_drive | 31,781 | 165 | positive |
| 2026-11-01 | - | clock enables, board wiring, SDRAM, LR card | 23,394 | 130 | positive |
| 2026-11-01 | - | scaffold, first full compile | 16,335 | 43 | +0.519 |

Of 41,910 ALMs and 553 M10K. The HR bitmap is 128 M10K (eight 16K x 8
lanes); the disk cylinder buffers and formats about 240; the k8000 chips
are about 15,000 ALMs (ROADMAP open work).
