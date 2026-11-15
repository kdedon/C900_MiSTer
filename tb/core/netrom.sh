#!/usr/bin/env bash
# The LANCE card's boot ROM, end to end, before the BIOS has its hook:
# the BIOS fetches ndhook (firmware/lance_bootrom/test/hook.c) by (le),
# and ndhook does the hook's steps on the card ROM loaded as boot2.rom:
# probe, copy, checksum, map, init; then streams ndbig.bin (over 64 KB)
# through nd.read with a restart, and loads and jumps to the boot file
# ndprog.out.  The card ROM gets its address from Main's IP configuration
# words (static) or by BOOTP.
#   tb/core/netrom.sh <dir> static|bootp
# dir: boot0.rom, a BIOS with (le), defaults --memtest skip --boot monitor
# --wait 1; boot1.rom.
# PASS: NDPROG OK, ndbig.bin's size and sum, its copy at 0x100000, the
# BIOS's romconf left unchanged, ndbig.bin read to its end and requested again, no bad
# frame.
# Outputs in tb/core/obj_dir/netrom_<mode>/.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
[ $# -eq 2 ] || { sed -n 2,15p "$0"; exit 2; }
roms="$(realpath "$1")"; mode="$2"
cr="${here}/../../firmware/lance_bootrom"
out="${here}/obj_dir/netrom_${mode}"
rm -rf "${out}"; mkdir -p "${out}/srv"
make -s -C "${cr}" test > "${out}/cardrom.log" 2>&1 || { cat "${out}/cardrom.log"; exit 1; }
cp "${cr}/build/ndhook.out" "${cr}/build/ndprog.out" "${cr}/build/ndbig.bin" "${out}/srv/"
make -s -C "${here}" > "${out}/build.log" 2>&1 || { tail -30 "${out}/build.log"; exit 1; }

hex() { printf '%s' "$1" | od -An -tx1 | tr -d ' \n'; }
echo "$(hex $'\n? ') $(hex $'(le)10.0.9.1:ndhook.out\r')" > "${out}/serin.txt"
size="$(stat -c %s "${cr}/build/ndbig.bin")"

"${here}/obj_dir/tb_core" +rom="${roms}/boot0.rom" +rom1="${roms}/boot1.rom" +nocard +lance +speed=3 +maxcyc=30000000 \
  +netpeer="${out}/srv" +netlog="${out}/net.pcap" +serin="${out}/serin.txt" \
  +landma="${out}/landma.txt" +ndcfg="${mode}" +ndfile=ndprog.out \
  +rom2="${cr}/build/boot2.rom" \
  "+stopstr=NDPROG OK" +memdump="${out}/image.bin" +memfrom=100000 +memlen="${size}" \
  > "${out}/run.log" 2>&1

grep '^SCC B' "${out}/run.log" | sed -E "s/^[^']*'(.*)'$/\1/" | tr -d '\n' |
  sed 's/\\x0d//g; s/\\x0a/\n/g' > "${out}/console.txt"
grep '^NETPEER' "${out}/run.log" | tail -1
ok=1
need() { grep -q -- "$1" "${out}/console.txt" || { echo "netrom: no \"$1\""; ok=; }; }
need "$(python3 "${cr}/test/mkbig.py" /dev/null)"
need "restart ok"
need "romconf unchanged"
need "nd .* ndprog.out"
need "NDPROG OK"
grep -q '^NETPEER sent "ndbig.bin"' "${out}/run.log" || { echo "netrom: ndbig.bin not read to its end"; ok=; }
[ "$(grep -c '^NETPEER RRQ "ndbig.bin"' "${out}/run.log")" = 2 ] || { echo "netrom: ndbig.bin not read again"; ok=; }
grep -q '^NETPEER RRQ "ndprog.out"' "${out}/run.log" || { echo "netrom: no RRQ for ndprog.out"; ok=; }
if grep -q '^NETPEER bad frame' "${out}/run.log"; then grep '^NETPEER bad frame' "${out}/run.log" | sort | uniq -c; ok=; fi
cmp -s "${cr}/build/ndbig.bin" "${out}/image.bin" || { echo "netrom: ndbig.bin in RAM differs"; ok=; }
if [ -z "${ok}" ]; then tail -20 "${out}/console.txt"; echo "netrom: FAIL"; exit 1; fi
echo "netrom: PASS, ${mode}, $(grep -o '^stop: .*' "${out}/run.log")"
