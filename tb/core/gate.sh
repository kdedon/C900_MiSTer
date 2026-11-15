#!/usr/bin/env bash
# Whole-core gate: boots the C900 boot ROM in Verilator and compares the
# result with captured reference traces.  The boot ROM's memory-test loop
# counts are patched (skip_memtest.patch).
#   1. no display card, no disks: banner, self-tests and "Automatic boot in
#      progress" on SCC U74 channel B; floppy and hard disk probe DMA
#   2. a key pressed in the keyboard matrix reaches the CPU
#   3. LR card: banner in the LR character RAM, nothing on the SCC, a video
#      frame, self-tests through "MMU  (U2) test: OK"
#   4. synthetic hard disk, mounted at Z8001 clock 19,200,000: auto-boot reads
#      block 2; DMA cycles and SCC bytes in order (clocks not compared: drive
#      spindle phase)
#   5. synthetic floppy in drive 1, mounted at 9,000,000: same (clocks not
#      compared: 8049 clock drift)
#   every step: the DRAM in SDRAM through c900_sdram and the vendored
#      controller (cycle-level chip model); every read meets the C900
#      deadline, no chip protocol error, every refresh starts in a
#      refresh_ok or post-ack clock within 13 clocks of falling due, and
#      the next request comes at least 4 clocks after it; the CPU never
#      fetches an undefined first word
#   6. HR card, no disks: Z-bus transactions to 9.2M Z8001 clocks (md5 of the
#      stream; the undriven lane of a byte read is not compared), writes to
#      control register 0404H, and the final HR bitmap
#   7. HR card, hr_rmw.s in place of the BIOS: every bitmap read returns the
#      last value written, and the bitmap ends as written
#   8. turbo CPU clock, 10, 12 and 48 MHz, synthetic hard disk: the Go HD run's
#      DMA cycles and SCC bytes (clocks not compared) open the turbo runs'
#      (they get there sooner); no SDRAM error or forced refresh (a read may
#      be late: the CPU waits for the ack); no SCC or CIO access during DMA.
#      48 MHz: SCC bytes through "read error: status=0xA1 " (the run's end)
#   9. DMA /DS: mkcs1.py polls SCC U74, CIO U70 or, with the LR card, SCC
#      U31 or U36 while the 8716 writes a sector.  The chips still hold the
#      select of that I/O cycle's /AS when DMA words with A7 = 0 and = 1
#      follow, and take none of them: one access per /AS
#  10. S1: _MRESET Low for 0.561 s (3,366,000 clocks), _PRESET stays High,
#      the BIOS starts again with the OSD options set at the press: 512K RAM
#      (press at Z8001 clock 400,000), the LR card (press at 2,000,000)
#  11. APU: mkfpu.py's test in place of the BIOS, "YAMDQSTP" with the Z8070
#      at 6, 10, 12 and 48 MHz, "NEP" (Extended Instruction trap) without it at
#      6 and 48 MHz; fpu_fd.img (mkfpu.py flop, mounted at 9,000,000) booted
#      by the ROM from drive 1: "NEP" without the APU
#  12. LC card: lc_probe.s in place of the BIOS writes and reads back 8563
#      R12/R13 and a RAM byte through R18/R19/R31, reads 01FB (unclaimed:
#      FF), then the ID byte at 01FF, at 6 and 48 MHz; with no card every
#      read is FF
#  13. card reads and writes: cardrw.s in place of the BIOS with the LR, HR
#      and LC cards at 6, 10, 12 and 48 MHz writes and reads back the LR
#      character RAM, the HR bitmap and ports and 8563 R12/R13 (the fitted
#      card's part reads back right); hr_rmw.s at 48 MHz ends with the 6 MHz
#      bitmap.  In these runs, steps 7, 11 and 12, every word the CPU takes
#      on a read is the bus word of that cycle (CPUMON)
#  14. SCC and CIO recovery: iorec.s in place of the BIOS, back-to-back
#      reads and writes to SCC U74, CIOs U70 and U66 and the LR card's SCCs
#      U31 and U36 at 6, 10, 12 and 48 MHz: /DS stays High at least 6 PCLK
#      + 200 ns (SCC) or 1000 ns (CIO) between two accesses to one chip
#  15. SCC U74 B transmit: sertx.s in place of the BIOS programs COHERENT's
#      9600 baud setup and sends six bytes; the TxD pin and the HPS UART
#      carry them with each card and none, at 6 and 48 MHz
#  16. LANCE card: lance.s in place of the BIOS at 6 and 48 MHz sends a
#      frame in external and internal loopback: TINT and RINT, vector 88,
#      the frame in RAM
#  17. boot ROM size: mkrom64.py's test in place of the BIOS reads 0x8000
#      and 0x0000 and jumps to 0x8010: with a 23128 pair (32 KB boot0.rom)
#      0x8000 reads as 0x0000; with a 27256 pair (64 KB boot0.rom, at 6
#      and 48 MHz) the upper half's own words, and its code runs
#  18. FCPF: fcpf.patch (mkfcpf.py) in place of the BIOS compares 2.0 with
#      0.75, 0.75 with 2.0 and 2.0 with itself at 6, 10, 12 and 48 MHz; the
#      CPU flags after each are 08 A8 40 (>, <, =)
#  19. RAM map: ramsz.s in place of the BIOS writes each physical segment
#      08-FF and reads it back, with 512K and 1M boards and each RAM card
#      (none, 2M, 4M, 8M, 15M): fitted segments read back their own word,
#      the rest FFFF, and only fitted segments take SDRAM writes
# The runs share two cores (GATE_SLOTS): the no-card run forks the keyboard,
# floppy, hard disk and S1 runs at their first difference (the image mounts
# then, before the BIOS probes the drive), and each stops when its check is
# complete.  About 2.5 hours.
#   tb/core/gate.sh [-q] <rom_dir>      boot0.rom and boot1.rom built from the
#                                       C900 ROM dumps in rom_dir
#   -q: quick gate, about 10 minutes: steps 1 (SCC to 990,000 clocks), 3
#       (banner and frame), 6 (Z-bus to 1,800,000 clocks, the 0404H writes,
#       read-back), 7, 9, 11 (6 and 48 MHz, no floppy), 12-19
#   GATE_REUSE=1 tb/core/gate.sh [-q]   check the previous run's outputs again
#                                       (no rom_dir)
#   GATE_SLOTS=<n> cores (default 2); GATE_SLOTDIR=<dir> shares them between gates
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="${here}/../.."
cd "${here}"
quick=
if [ "${1:-}" = -q ]; then quick=1; shift; fi
mkdir -p obj_dir
rom=obj_dir/boot0.rom rom1=obj_dir/boot1.rom
if [ -n "${1:-}" ]; then
  "${root}/scripts/make_boot_rom.sh" "$1" obj_dir >/dev/null
elif [ -z "${GATE_REUSE:-}" ] || [ ! -f "${rom}" ]; then
  echo "usage: tb/core/gate.sh [-q] <rom_dir>: the C900 ROM dumps (not in this repo)" >&2
  exit 2
fi
make -s > obj_dir/build.log 2>&1 || { tail -30 obj_dir/build.log; exit 1; }
python3 mkimg.py hd obj_dir/hd.img
python3 mkimg.py fd obj_dir/fd.img
python3 mkcs1.py scc > obj_dir/cs1_scc.patch
python3 mkcs1.py cio > obj_dir/cs1_cio.patch
python3 mkcs1.py lr0 > obj_dir/cs1_lr0.patch
python3 mkcs1.py lr1 > obj_dir/cs1_lr1.patch
python3 mkrom64.py "${rom}" obj_dir/rom32.rom obj_dir/rom64.rom
cp fpu_fd.img obj_dir/fpu_fd.img && truncate -s 1224704 obj_dir/fpu_fd.img

# One lock file per core; a waiting run takes a free one in +prio order.
# GATE_SLOTDIR=<dir> shares the cores of another gate using that directory.
slots="${GATE_SLOTDIR:-obj_dir/slots}"
if [ -z "${GATE_SLOTDIR:-}" ]; then rm -rf "${slots}"; fi
mkdir -p "${slots}"
ls "${slots}"/slot* >/dev/null 2>&1 ||
  for i in $(seq 1 "${GATE_SLOTS:-2}"); do touch "${slots}/slot${i}"; done
run() {
  local log=$1 prio=$2; shift 2
  ./obj_dir/tb_core +rom="${rom}" +rom1="${rom1}" +slots="${slots}" +prio="${prio}" "$@" > "obj_dir/${log}.log" &
}
tb() { run "$@" +patch=skip_memtest.patch; }
# fpu.patch prints 8 bytes with the APU, 3 without
fpu() { run "$@" +patch=fpu.patch +nocard +maxcyc=400000; }
fcpf() { for s in 0 1 2 3; do run "fcpf_s${s}" 60 +patch=fcpf.patch +nocard +fpu +speed=${s} +maxcyc=3000 +stopbytes=3; done; }
# lc_probe.patch replaces the BIOS
lc() {
  run lc_6 70 +patch=lc_probe.patch +maxcyc=2000 +lc
  run lc_48 70 +patch=lc_probe.patch +maxcyc=2000 +lc +speed=3
  run lc_none 70 +patch=lc_probe.patch +maxcyc=2000 +nocard
}
cardrw() {
  for c in lr hr lc; do
    card=; [ "${c}" = lr ] || card=+${c}
    for s in 0 1 2 3; do
      run "cardrw_${c}_s${s}" 65 +patch=cardrw.patch ${card} +speed=${s} +maxcyc=140000 \
        +trace=obj_dir/cardrw_${c}_s${s}.txt +tracemax=100000000
    done
  done
  for s in 0 1 2 3; do run "iorec_s${s}" 65 +patch=iorec.patch +speed=${s} +maxcyc=6000; done
  for c in lr hr lc nocard; do
    card=; [ "${c}" = lr ] || card=+${c}
    for s in 0 3; do run "sertx_${c}_s${s}" 65 +patch=sertx.patch ${card} +speed=${s} +maxcyc=45000; done
  done
}
lance() {
  for s in 0 3; do
    run "lance_s${s}" 65 +patch=lance.patch +nocard +lance +speed=${s} +maxcyc=30000 \
      +trace=obj_dir/lance_s${s}.txt +tracemax=100000000
  done
}
romsz() {
  for r in rom32_s0:rom32 rom64_s0:rom64 rom64_s3:rom64; do
    l=${r%%:*}
    ./obj_dir/tb_core +rom=obj_dir/${r#*:}.rom +rom1="${rom1}" +slots="${slots}" +prio=70 +nocard +speed=${l: -1} +maxcyc=600 \
      +trace=obj_dir/${l}.txt > "obj_dir/${l}.log" &
  done
}
ramsz() {
  for m in 0 1; do
    for c in 0 1 2 3 4; do
      run "ramsz_${m}${c}" 65 +patch=ramsz.patch +nocard +ram=${m} +card=${c} +maxcyc=80000 \
        +trace=obj_dir/ramsz_${m}${c}.txt +tracemax=100000000
    done
  done
}
cs1() {
  for c in scc cio lr0 lr1; do
    card=+nocard
    [ "${c#lr}" = "${c}" ] || card=   # lr0, lr1: LR card fitted
    run "cs1_${c}" 50 +patch=obj_dir/cs1_${c}.patch ${card} +hd=obj_dir/hd.img +maxcyc=530000
  done
}
if [ -z "${GATE_REUSE:-}" ] && [ -n "${quick}" ]; then
  tb headless 0 +nocard +maxcyc=1000000 +scctx=obj_dir/headless_scc.txt
  tb hr 1 +hr +maxcyc=1800000 +trace=obj_dir/hr_trace.txt +tracemax=100000000
  tb lr 2 +maxcyc=600000 +screen +frame=obj_dir/lr_frame.pgm +frameat=380000
  run hr_rmw 40 +patch=hr_rmw.patch +hr +maxcyc=330000 +hrvram=obj_dir/hr_rmw.pbm
  run hr_rmw_s3 40 +patch=hr_rmw.patch +hr +speed=3 +maxcyc=330000 +hrvram=obj_dir/hr_rmw_s3.pbm
  cardrw
  lance
  cs1
  fpu fpu_s0 60 +fpu +stopbytes=8; fpu fpu_s3 60 +fpu +speed=3 +stopbytes=8; fpu nofpu_s0 60 +stopbytes=3
  fcpf
  lc
  romsz
  ramsz
  wait
elif [ -z "${GATE_REUSE:-}" ]; then
  # <fork clock> <log> <plusargs>: each forks just before its first change
  cat > obj_dir/forks.txt <<EOT
390000 obj_dir/s1.log +prio=20 +s1=400000 +s1ram=1 +maxcyc=9800000 +stopbytes=125 +scctx=obj_dir/s1_scc.txt
1990000 obj_dir/s1lr.log +prio=30 +s1=2000000 +s1lr +screen +maxcyc=5600000 +scctx=obj_dir/s1lr_scc.txt
5290000 obj_dir/kbd.log +prio=10 +key=45 +keyat=5300000 +keyhold=100000 +maxcyc=5600000
9000000 obj_dir/nofpu_fd.log +prio=5 +fd1=obj_dir/fpu_fd.img +maxcyc=18400000 +stopbytes=209
9000000 obj_dir/fd.log +prio=15 +fd1=obj_dir/fd.img +maxcyc=14600000 +scctx=obj_dir/fd_scc.txt +dmalog=obj_dir/fd_dma.txt
19200000 obj_dir/hd.log +prio=1 +hd=obj_dir/hd.img +maxcyc=19800000 +stopbytes=248 +scctx=obj_dir/hd_scc.txt +dmalog=obj_dir/hd_dma.txt
EOT
  tb headless 0 +nocard +maxcyc=19300000 +scctx=obj_dir/headless_scc.txt +dmalog=obj_dir/headless_dma.txt \
    +forks=obj_dir/forks.txt
  for s in 1 2 3; do
    tb hd_s${s} $((s + 1)) +nocard +hd=obj_dir/hd.img +speed=${s} +maxcyc=$((s == 1 ? 18200000 : s == 2 ? 16900000 : 14000000)) \
      +stopbytes=$((s == 3 ? 230 : 248)) +scctx=obj_dir/hd_s${s}_scc.txt +dmalog=obj_dir/hd_s${s}_dma.txt
  done
  tb hr 6 +hr +maxcyc=9200000 +trace=obj_dir/hr_trace.txt +tracemax=100000000 +hrvram=obj_dir/hr_vram.pbm
  tb lr 7 +maxcyc=8100000 +screen +frame=obj_dir/lr_frame.pgm +frameat=380000
  run hr_rmw 40 +patch=hr_rmw.patch +hr +maxcyc=330000 +hrvram=obj_dir/hr_rmw.pbm
  run hr_rmw_s3 40 +patch=hr_rmw.patch +hr +speed=3 +maxcyc=330000 +hrvram=obj_dir/hr_rmw_s3.pbm
  cardrw
  lance
  cs1
  for s in 0 1 2 3; do fpu fpu_s${s} 60 +fpu +speed=${s} +stopbytes=8; done
  fpu nofpu_s0 60 +stopbytes=3; fpu nofpu_s3 60 +speed=3 +stopbytes=3
  fcpf
  lc
  romsz
  ramsz
  wait
fi

# same <what> <ref> <file>: exact compare
same() {
  if ! diff -q "$2" "$3" >/dev/null; then
    echo "FAIL $1: differs from the Go reference ($2):"
    diff "$2" "$3" | head -10
    exit 1
  fi
}
# SDRAM: every read on time, no forced refresh, no chip protocol error, in
# every run
logs="headless hd kbd fd lr hr"
[ -z "${quick}" ] || logs="headless lr hr"
for l in ${logs}; do
  grep -q "^SDRAM: .* (0 late), .* 0 forced), .* 0 errors$" "obj_dir/${l}.log" ||
    { echo "FAIL ${l}: SDRAM"; grep "^SDRAM" "obj_dir/${l}.log"; exit 1; }
  awk '/^SDRAM scheduling:/ { w = $7; n = $13 }
       END { exit !(w != "" && w + 0 <= 13 && n + 0 >= 4) }' "obj_dir/${l}.log" ||
    { echo "FAIL ${l}: SDRAM refresh scheduling"; grep "^SDRAM sched" "obj_dir/${l}.log"; exit 1; }
done
! grep -q "^UNDEF" obj_dir/*.log ||
  { echo "FAIL: undefined first word"; grep -H "^UNDEF" obj_dir/*.log | head; exit 1; }
echo "SDRAM: every read acked 4 clocks after the request, no forced refresh, in all runs:"
for l in ${logs}; do grep -h "^SDRAM: \|^SDRAM sched" "obj_dir/${l}.log"; done | sed 's/^/  /'

text() { awk '{printf "%s", $4}' "$1" | xxd -r -p | tr -d '\r'; }

# headless, no disks
if [ -n "${quick}" ]; then
  awk '$2 < 990000' ref/go_headless_skip_scc.txt > obj_dir/ref_scc_cut.txt
  awk '$2 < 990000' obj_dir/headless_scc.txt > obj_dir/headless_scc_cut.txt
  same "headless SCC" obj_dir/ref_scc_cut.txt obj_dir/headless_scc_cut.txt
  t="$(text obj_dir/headless_scc_cut.txt)"
  echo "headless: $(wc -l < obj_dir/headless_scc_cut.txt) SCC bytes at the Go reference's Z8001 clocks:"
  echo "${t}" | sed 's/^/  | /'
  echo "${t}" | grep -q "^Commodore C900 diagnostics V1.0 (6/14/85)$" || { echo "FAIL headless: no banner"; exit 1; }
else
awk '$2 < 19230000' ref/go_headless_skip_scc.txt > obj_dir/ref_scc_cut.txt
same "headless SCC" obj_dir/ref_scc_cut.txt obj_dir/headless_scc.txt
grep " 08001[c-f] \| 08001[0-7] " ref/go_headless_dma.txt > obj_dir/ref_fd_probe.txt
grep " 08001[c-f] \| 08001[0-7] " obj_dir/headless_dma.txt > obj_dir/fd_probe.txt
same "headless floppy-probe DMA (order, clock, address, word)" obj_dir/ref_fd_probe.txt obj_dir/fd_probe.txt
cut -d' ' -f1,3- ref/go_headless_dma.txt | grep -v " 08001" > obj_dir/ref_hd_probe.txt
cut -d' ' -f1,3- obj_dir/headless_dma.txt | grep -v " 08001" > obj_dir/hd_probe.txt
if ! diff -q <(cut -d' ' -f1-3 obj_dir/ref_hd_probe.txt) <(cut -d' ' -f1-3 obj_dir/hd_probe.txt) >/dev/null; then
  echo "FAIL headless: hard disk probe DMA addresses differ from the Go reference"; exit 1
fi
t="$(text obj_dir/headless_scc.txt)"
echo "headless: $(wc -l < obj_dir/headless_scc.txt) SCC bytes at the Go reference's Z8001 clocks; floppy probe $(wc -l < obj_dir/fd_probe.txt) DMA cycles at the Go clocks:"
echo "${t}" | sed 's/^/  | /'
echo "${t}" | grep -q "MMU  (U2) test: OK" || { echo "FAIL headless: no MMU OK"; exit 1; }
echo "${t}" | grep -q "Automatic boot in progress" || { echo "FAIL headless: no auto-boot"; exit 1; }
hs_core="$(grep ' 08000c W' obj_dir/headless_dma.txt | tail -1 | cut -d' ' -f5)"
hs_go="$(grep ' 08000c W' ref/go_headless_dma.txt | tail -1 | cut -d' ' -f5)"
[ "${hs_core}" = "${hs_go}" ] || { echo "FAIL headless: hard disk probe status ${hs_core}, Go ${hs_go}"; exit 1; }
echo "  hard disk probe status ${hs_core}, as in the Go simulator"

# keyboard: matrix key 45 ('h', XT 0x23) pressed at Z8001 clock 5,300,000,
# during the BIOS power-on keystroke poll.  The 6500/1 scans it and sends the
# make code over the cable, the 311075 board presents it to CIO U70, and the
# CPU reads it (PADATA = DAV + 0x23, PCDATA PC2 = 0).
grep -q "^KBD byte 23 " obj_dir/kbd.log || { echo "FAIL keyboard: no make code from the cable"; exit 1; }
grep "^IORD [0-9]* 001[bf] " obj_dir/kbd.log | awk '{print $2 - 1, $3}' > obj_dir/kbd_rd.txt
same "keyboard reads" ref/go_headless_key.txt obj_dir/kbd_rd.txt
ka="$(awk '$2 == "001b" {print $1; exit}' ref/go_headless_key.txt)"
grep -q "^IORD $((ka + 1)) 001b a3$" obj_dir/kbd.log ||
  { echo "FAIL keyboard: scancode not read as make 0x23"; grep "^IORD" obj_dir/kbd.log; exit 1; }
echo "keyboard: make 0x23 read by the CPU at Z8001 clock $((ka + 1)), as in the Go simulator"
fi

# LR card
grep -q "^SCC" obj_dir/lr.log && { echo "FAIL LR: console went to the SCC"; exit 1; }
grep -q "^01|Commodore C900 diagnostics V1.0 (6/14/85) " obj_dir/lr.log ||
  { echo "FAIL LR: banner not in the character RAM"; grep "^0[0-3]|" obj_dir/lr.log; exit 1; }
[ -n "${quick}" ] || grep -q "^06|MMU  (U2) test: OK " obj_dir/lr.log ||
  { echo "FAIL LR: no MMU OK on the screen"; grep "^0[0-9]|" obj_dir/lr.log; exit 1; }
grep -q "^frame: wrote" obj_dir/lr.log || { echo "FAIL LR: no video frame"; exit 1; }
echo "LR: screen rows 0-7 and a 720x350 frame in obj_dir/lr_frame.pgm:"
grep "^0[0-7]|" obj_dir/lr.log | sed 's/ *|$/|/; s/^/  /'

if [ -z "${quick}" ]; then
# hard disk
same "HD DMA (order, address, word)" <(cut -d' ' -f1,3- ref/go_hd_dma.txt) <(cut -d' ' -f1,3- obj_dir/hd_dma.txt)
same "HD SCC bytes" <(cut -d' ' -f1,3- ref/go_hd_scc.txt) <(cut -d' ' -f1,3- obj_dir/hd_scc.txt)
echo "hard disk: $(wc -l < obj_dir/hd_dma.txt) DMA cycles (block 2 into 0x080400) and the SCC text as in the Go simulator:"
text obj_dir/hd_scc.txt | tail -1 | sed 's/^/  | /'
# floppy
same "floppy DMA (order, address, word)" <(cut -d' ' -f1,3- ref/go_fd_dma.txt) <(cut -d' ' -f1,3- obj_dir/fd_dma.txt)
same "floppy SCC bytes" <(cut -d' ' -f1,3- ref/go_fd_scc.txt) <(cut -d' ' -f1,3- obj_dir/fd_scc.txt)
echo "floppy: $(wc -l < obj_dir/fd_dma.txt) DMA cycles (block 2 into 0x080400) and the SCC text as in the Go simulator:"
text obj_dir/fd_scc.txt | tail -1 | sed 's/^/  | /'
fi
# HR card
norm() { grep -v '^0 st=0 ' "$1" | sed 's/ pa=.*//' |
  awk '$4 == "R" && $5 == "B" { if ($3 ~ /[13579bdf]$/) sub(/d=../, "d=--"); else $7 = substr($7, 1, 4) "--" } { print }'; }
if [ -n "${quick}" ]; then
  [ "$(norm obj_dir/hr_trace.txt | awk '$1 < 1800000' | md5sum | cut -d' ' -f1)" = "$(cat ref/go_hr_tx_1800k.md5)" ] ||
    { echo "FAIL HR: Z-bus transactions to 1,800,000 differ from the Go reference"; exit 1; }
  same "HR control register writes" ref/go_hr_io.txt <(grep -E " st=[23] 00:04[0-9a-f]{2} " obj_dir/hr_trace.txt | sed 's/ pa=.*//')
  echo "HR: $(norm obj_dir/hr_trace.txt | awk '$1 < 1800000' | wc -l) Z-bus transactions to Z8001 clock 1,800,000 and the 0404H writes as in the Go simulator"
else
[ "$(norm obj_dir/hr_trace.txt | md5sum | cut -d' ' -f1)" = "$(cat ref/go_hr_tx.md5)" ] ||
  { echo "FAIL HR: Z-bus transactions differ from the Go reference (rerun ref/goref -board hr to diff)"; exit 1; }
same "HR control register writes" ref/go_hr_io.txt <(grep -E " st=[23] 00:04[0-9a-f]{2} " obj_dir/hr_trace.txt | sed 's/ pa=.*//')
same "HR bitmap" <(gzip -dc ref/go_hr_vram.pbm.gz) obj_dir/hr_vram.pbm
echo "HR: $(norm obj_dir/hr_trace.txt | wc -l) Z-bus transactions, the 0404H writes and the bitmap ($(tr -cd 1 < obj_dir/hr_vram.pbm | wc -c) pixels lit) as in the Go simulator"
fi
grep -q "^HRMON: [0-9]* reads, [0-9]* writes, 0 read mismatches, 0 bitmap bytes differ$" obj_dir/hr.log ||
  { echo "FAIL HR: bitmap read-back"; grep "^HRMON" obj_dir/hr.log | head; exit 1; }
# hr_rmw.s: 8425 reads and 10473 writes when it reaches its park loop
for l in hr_rmw hr_rmw_s3; do
  grep -q "^HRMON: 8425 reads, 10473 writes, 0 read mismatches, 0 bitmap bytes differ$" obj_dir/${l}.log ||
    { echo "FAIL HR read-modify-write ${l}"; grep "^HRMON" obj_dir/${l}.log | head; exit 1; }
done
same "HR read-modify-write bitmap at 48 MHz" obj_dir/hr_rmw.pbm obj_dir/hr_rmw_s3.pbm
echo "HR read-back: $(grep '^HRMON:' obj_dir/hr.log | cut -d' ' -f2-) (BIOS); $(grep '^HRMON:' obj_dir/hr_rmw.log | cut -d' ' -f2-) (hr_rmw.s)"
if [ -z "${quick}" ]; then
# turbo
# prefix <what> <ref> <file>: <ref> is the head of <file>, clocks cut
prefix() {
  cut -d' ' -f1,3- "$2" > obj_dir/prefix_ref.txt
  cut -d' ' -f1,3- "$3" | head -n "$(wc -l < obj_dir/prefix_ref.txt)" > obj_dir/prefix_run.txt
  if ! diff -q obj_dir/prefix_ref.txt obj_dir/prefix_run.txt >/dev/null; then
    echo "FAIL $1: the Go reference ($2) is not a prefix:"
    diff obj_dir/prefix_ref.txt obj_dir/prefix_run.txt | head -10
    exit 1
  fi
}
for s in 1 2 3; do
  l="obj_dir/hd_s${s}.log"
  grep -q "^SDRAM: .* 0 forced), .* 0 errors$" "${l}" ||
    { echo "FAIL turbo ${s}: SDRAM"; grep "^SDRAM" "${l}"; exit 1; }
  prefix "turbo ${s} HD DMA" ref/go_hd_dma.txt "obj_dir/hd_s${s}_dma.txt"
  if [ "${s}" != 3 ]; then
    prefix "turbo ${s} HD SCC bytes" ref/go_hd_scc.txt "obj_dir/hd_s${s}_scc.txt"
  else
    head -n 230 ref/go_hd_scc.txt > obj_dir/ref_hd_boot_scc.txt
    prefix "turbo ${s} HD SCC bytes" obj_dir/ref_hd_boot_scc.txt "obj_dir/hd_s${s}_scc.txt"
  fi
  grep -q "^DMAIO: 0 " "${l}" || { echo "FAIL turbo ${s}: SCC/CIO access during DMA"; grep "^DMAIO" "${l}" | head -5; exit 1; }
  echo "turbo +speed=${s}: the Go HD DMA and SCC text open the run ($(wc -l < "obj_dir/hd_s${s}_dma.txt") DMA cycles); $(grep '^SDRAM: ' "${l}")"
done
fi
# "<kind> <chip> A7" of each DMA /DS into a held select (DMASEL) and each
# access a chip took during DMA (DMAIO)
for c in scc cio lr0 lr1; do
  l="obj_dir/cs1_${c}.log"
  awk '/^DMA(SEL|IO) / { a = $5; d = index("0123456789abcdef", substr(a, 5, 1)) - 1
                         print $1, $3, (d >= 8) }' "${l}" | sort | uniq -c > "obj_dir/cs1_${c}.txt"
  ! grep -q " DMAIO " "obj_dir/cs1_${c}.txt" ||
    { echo "FAIL DMA /DS ${c}: a chip took a DMA word:"; cat "obj_dir/cs1_${c}.txt"; exit 1; }
done
grep -q " DMASEL U74 0$" obj_dir/cs1_scc.txt && grep -q " DMASEL U74 1$" obj_dir/cs1_scc.txt &&
  grep -q " DMASEL U70 0$" obj_dir/cs1_cio.txt && grep -q " DMASEL U70 1$" obj_dir/cs1_cio.txt &&
  grep -q " DMASEL U31 " obj_dir/cs1_lr0.txt && grep -q " DMASEL U36 " obj_dir/cs1_lr1.txt ||
  { echo "FAIL DMA /DS: no held select at A7 = 0 and = 1"; cat obj_dir/cs1_{scc,cio,lr0,lr1}.txt; exit 1; }
echo "DMA /DS into a held select (count, kind, chip, A7):"
cat obj_dir/cs1_{scc,cio,lr0,lr1}.txt | sed 's/^/  /'
if [ -z "${quick}" ]; then
# S1
for r in "s1 400001 3766001" "s1lr 2000001 5366001"; do
  set -- ${r}
  l="obj_dir/${1}.log"
  [ "$(grep -c "^MRESET" "${l}")" = 2 ] && grep -q "^MRESET  *Low @${2} (PRESET 1)" "${l}" &&
    grep -q "^MRESET High @${3} (PRESET 1)" "${l}" ||
    { echo "FAIL ${1}: _MRESET pulse"; grep "^MRESET\|^PRESET" "${l}"; exit 1; }
  grep -q "^PRESET Low" "${l}" && { echo "FAIL ${1}: _PRESET fell"; exit 1; }
done
t="$(text obj_dir/s1_scc.txt)"
[ "$(grep -c "^Commodore C900 diagnostics" <<< "${t}")" = 2 ] &&
  grep -q "^Memory test: 512K OK" <<< "${t}" ||
  { echo "FAIL S1: no restart with 512K"; echo "${t}"; exit 1; }
[ "$(text obj_dir/s1lr_scc.txt | grep -c "^Commodore C900 diagnostics")" = 1 ] &&
  grep -q "^01|Commodore C900 diagnostics V1.0 (6/14/85) " obj_dir/s1lr.log ||
  { echo "FAIL S1 LR: banner not on the LR card after S1"; grep "^0[0-3]|" obj_dir/s1lr.log; exit 1; }
echo "S1: _MRESET Low 3,366,000 Z8001 clocks, _PRESET High; the BIOS restarts with 512K, and on the LR card"
fi
# LC probe: the reads other than the 8563 status, in order
lcreads() { awk '$1 == "LCMON" && $3 == "R" && $4 != "0181" { printf "%s=%s ", $4, $5 }' "$1"; }
for r in "6:0183=5a 0183=a5 0183=77 01fb=ff 01ff=c1 " "48:0183=5a 0183=a5 0183=77 01fb=ff 01ff=c1 " \
         "none:0183=ff 0183=ff 0183=ff 01fb=ff 01ff=ff "; do
  c="${r%%:*}"
  [ "$(lcreads "obj_dir/lc_${c}.log")" = "${r#*:}" ] || { echo "FAIL LC ${c}: $(lcreads "obj_dir/lc_${c}.log")"; exit 1; }
done
# The 8568 INTR on CN11 _NVI reaches the CPU pin: it falls after the R31
# write, the pin is U62 /Q2 AND the card's line, and no card leaves it High.
lcnvi() { awk '$1 == "LCNVI" { if ($4 != ($6 && $8)) bad++; if ($4 == 0 && $6 == 1 && $8 == 0) f++ } END { print (bad ? "bad" : f + 0) }' "$1"; }
for c in 6 48; do
  n="$(lcnvi "obj_dir/lc_${c}.log")"
  [ "${n}" != bad ] && [ "${n}" -ge 1 ] || { echo "FAIL LC ${c}: CPU _NVI from the 8568 INTR (${n})"; exit 1; }
done
[ "$(lcnvi obj_dir/lc_none.log)" = 0 ] || { echo "FAIL LC none: _NVI moved without a card"; exit 1; }
echo "LC: 8568 R12/R13, RAM byte, 01FB unclaimed, ID C1 (6 and 48 MHz); no card: FF; INTR on the CPU _NVI pin"
# Card reads and writes: the parts' wrong-read counts at 08:0F00-0F06, then C0DE
for c in lr hr lc; do
  for s in 0 1 2 3; do
    r="$(awk '$3 ~ /^08:0f0[0-8]$/ && $4 == "W" { printf "%s ", substr($7, 3) }' "obj_dir/cardrw_${c}_s${s}.txt")"
    set -- ${r}
    [ "$#" = 5 ] && [ "$5" = c0de ] || { echo "FAIL cardrw ${c} ${s}: did not finish (${r})"; exit 1; }
    case ${c} in lr) n=$1;; hr) n="$2 $3";; lc) n=$4;; esac
    [ "$(tr -d ' 0' <<< "${n}")" = "" ] || { echo "FAIL cardrw ${c} speed ${s}: wrong reads ${r}"; exit 1; }
  done
done
for s in 0 1 2 3; do
  [ "$(grep -c "^IOREC: U[0-9]* 19 gaps, min [0-9]* clocks, 0 short$" "obj_dir/iorec_s${s}.log")" = 5 ] ||
    { echo "FAIL SCC/CIO recovery speed ${s}:"; grep "^IOREC" "obj_dir/iorec_s${s}.log"; exit 1; }
done
echo "SCC/CIO recovery (min /DS High clocks U74 U70 U66 U31 U36):$(for s in 0 1 2 3; do echo -n " s${s}"; awk '/^IOREC/ { printf " %s", $6 }' "obj_dir/iorec_s${s}.log"; done)"
for c in lr hr lc nocard; do
  for s in 0 3; do
    for p in U74B UART; do
      t="$(awk -v p="${p}" '$1 == "TXD" && $2 == p { printf "%s ", $4 }' "obj_dir/sertx_${c}_s${s}.log")"
      [ "${t}" = "55 39 30 30 0d 0a " ] || { echo "FAIL SCC transmit ${c} speed ${s} ${p}: ${t}"; exit 1; }
    done
  done
done
echo "SCC U74 B transmit: TxD and the HPS UART carry the bytes with LR, HR, LC and no card at 6 and 48 MHz"
echo "cards: LR character RAM, HR bitmap and ports, 8563 R12/R13 read back at 6, 10, 12, 48 MHz; HR RMW at 48 MHz as at 6"
# APU
apu="fpu_s0:YAMDQSTP fpu_s1:YAMDQSTP fpu_s2:YAMDQSTP fpu_s3:YAMDQSTP nofpu_s0:NEP nofpu_s3:NEP nofpu_fd:NEP"
[ -z "${quick}" ] || apu="fpu_s0:YAMDQSTP fpu_s3:YAMDQSTP nofpu_s0:NEP"
for r in ${apu}; do
  l="obj_dir/${r%%:*}.log"
  t="$(awk '/^SCC B/ { t = $4 == "0a" ? "" : t substr($NF, 2, 1) } END { printf "%s", t }' "${l}")"
  [ "${t}" = "${r#*:}" ] || { echo "FAIL APU ${r%%:*}: \"${t}\", expected ${r#*:}"; exit 1; }
  grep -q "^SDRAM: .* 0 forced), .* 0 errors$" "${l}" || { echo "FAIL APU ${r%%:*}: SDRAM"; exit 1; }
done
for s in 0 1 2 3; do
  t="$(awk '/^SCC B/ { printf "%s ", $4 }' "obj_dir/fcpf_s${s}.log")"
  [ "${t}" = "08 a8 40 " ] || { echo "FAIL FCPF speed ${s}: flags ${t}"; exit 1; }
  grep -q "^SDRAM: .* 0 forced), .* 0 errors$" "obj_dir/fcpf_s${s}.log" || { echo "FAIL FCPF ${s}: SDRAM"; exit 1; }
done
echo "FCPF: flags 08 a8 40 (>, <, =) at 6, 10, 12, 48 MHz"
# LANCE card: per run CSR0 bits, RMD1, RMD3, wrong words, identifier (88
# on AD7:0, AD15:8 undriven)
for s in 0 3; do
  r="$(awk '$3 ~ /^08:0f(0[0-9a-f]|1[0-4])$/ && $4 == "W" { printf "%s ", substr($7, 3) }' "obj_dir/lance_s${s}.txt")"
  [ "${r}" = "06f2 0308 0024 0000 ff88 06f2 0308 0024 0000 ff88 c0de " ] || { echo "FAIL LANCE ${s}: ${r}"; exit 1; }
done
echo "LANCE: a 32-byte frame in external and internal loopback, TINT, RINT, vector 88, data in RAM, at 6 and 48 MHz"
# Boot ROM size: the words read at 0x8000 and 0x0000, then the first three
# fetched at 0x8010-0x8014
romrd() { awk '$NF ~ /^pa=00(8000|0000|8010|8012|8014)$/ && !s[$NF]++ { printf "%s:%s ", substr($NF, 6), substr($7, 3) }' "$1"; }
w0="$(od -An -tx1 -N1 "${rom}" | tr -d ' ')$(od -An -tx1 -N1 -j16384 "${rom}" | tr -d ' ')"
for r in "rom32_s0:8000:${w0} 0000:${w0} " "rom64_s0:8000:8000 0000:${w0} 8010:2103 8012:5a5a 8014:e8ff " \
         "rom64_s3:8000:8000 0000:${w0} 8010:2103 8012:5a5a 8014:e8ff "; do
  l=${r%%:*}
  got="$(romrd "obj_dir/${l}.txt")"
  [ "${r#*:}" = "${got:0:${#r}-${#l}-1}" ] || { echo "FAIL boot ROM ${l}: ${got}"; exit 1; }
  grep -q "^SDRAM: .* 0 forced), .* 0 errors$" "obj_dir/${l}.log" || { echo "FAIL boot ROM ${l}: SDRAM"; exit 1; }
done
grep -q "^SDRAM: [0-9]* reads (0 late)" obj_dir/rom64_s0.log || { echo "FAIL boot ROM: late read at 6 MHz"; exit 1; }
echo "boot ROM: 23128 pair aliased at 0x8000; 27256 pair's upper half read and run at 6 and 48 MHz"
# RAM map: the words read back from segments 08-FF, then C0DE; the segments
# that took SDRAM writes.  Card: from 18 up, less 37, 3E, 3F and FF, until
# 31, 64, 128 or 256 segments.
for m in 0 1; do
  for c in 0 1 2 3 4; do
    want="$(awk -v m=${m} -v c=${c} 'BEGIN {
      n = c ? 2 ^ (c + 4) : 0; if (c == 1) n = 31; if (c == 4) n = 256
      for (p = 8; p < 256; p++) {
        f = p < 16 || (p < 24 && m == 0)
        if (p >= 24 && p != 55 && p != 62 && p != 63 && p != 255 && n > 0) { f = 1; n-- }
        r = r sprintf("%s ", f ? sprintf("5a%02x", p) : "ffff"); if (f) s = s sprintf(" %02x", p)
      }
      printf "%sc0de |MEMSEG%s", r, s }')"
    l=obj_dir/ramsz_${m}${c}
    got="$(awk '$3 ~ /^08:(2[01]|0f08)/ && $4 == "W" { printf "%s ", substr($7, 3) }' "${l}.txt")|$(grep "^MEMSEG" "${l}.log")"
    [ "${got}" = "${want}" ] || { echo "FAIL RAM map ${m} card ${c}:"; echo " got  ${got}"; echo " want ${want}"; exit 1; }
    grep -q "^SDRAM: .* 0 forced), .* 0 errors$" "${l}.log" || { echo "FAIL RAM map ${m} card ${c}: SDRAM"; exit 1; }
  done
done
echo "RAM map: 512K and 1M boards with no card, 2M, 4M, 8M and 15M: segments 08-FF read back or FFFF as fitted"
# CPUMON in the runs that replace the BIOS
cm="hr_rmw hr_rmw_s3 lc_6 lc_48 lc_none lance_s0 lance_s3"
for c in lr hr lc; do for s in 0 1 2 3; do cm="${cm} cardrw_${c}_s${s}"; done; done
for s in 0 1 2 3; do cm="${cm} iorec_s${s} fcpf_s${s}"; done
for c in lr hr lc nocard; do for s in 0 3; do cm="${cm} sertx_${c}_s${s}"; done; done
for r in ${apu}; do [ "${r%%:*}" = nofpu_fd ] || cm="${cm} ${r%%:*}"; done
cm="${cm} rom32_s0 rom64_s0 rom64_s3"
for m in 0 1; do for c in 0 1 2 3 4; do cm="${cm} ramsz_${m}${c}"; done; done
for l in ${cm}; do
  grep -q "^CPUMON: [0-9]* reads, 0 mismatches$" "obj_dir/${l}.log" ||
    { echo "FAIL ${l}: the CPU took a read word off the bus word"; grep "^CPUMON" "obj_dir/${l}.log" | head -5; exit 1; }
done
echo "CPUMON: every CPU read word as the bus carried it in ${cm}"
if [ -n "${quick}" ]; then
  echo "APU: YAMDQSTP with the Z8070 at 6 and 48 MHz; NEP without it at 6 MHz"
  echo "gate (quick): PASS"
else
  echo "APU: YAMDQSTP with the Z8070 at 6, 10, 12, 48 MHz; NEP without it at 6 and 48 MHz and from the floppy"
  echo "gate: PASS"
fi
