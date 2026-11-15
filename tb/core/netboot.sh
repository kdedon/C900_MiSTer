#!/usr/bin/env bash
# LANCE network boot, end to end: the BIOS on the 48 MHz CPU types
# (le)10.0.9.1:<file> at its monitor and fetches the file by ARP and TFTP
# from the scripted host (netpeer.cpp) over the LANCE card and the DDR ring.
#   tb/core/netboot.sh [-l] <dir> <file> [text]
# dir: boot0.rom, a BIOS with (le), defaults --memtest skip --boot monitor
# --wait 1; boot1.rom.
# Default: the BIOS boots the file; PASS when SCC B prints text (default
# "NETBOOT OK").  -l: load only (the monitor's l); PASS on "Start address",
# with the file intact in the receive buffer (physical 0x140000, 1M RAM).
# Outputs in tb/core/obj_dir/netboot_<file>/: log, pcap, LANCE bus cycles.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
load=
if [ "${1:-}" = -l ]; then load=1; shift; fi
[ $# -ge 2 ] || { sed -n 2,11p "$0"; exit 2; }
roms="$(realpath "$1")"; file="$(realpath "$2")"; text="${3:-NETBOOT OK}"
name="$(basename "${file}")"
out="${here}/obj_dir/netboot_${name}"
rm -rf "${out}"; mkdir -p "${out}/srv"
cp "${file}" "${out}/srv/"
make -s -C "${here}" > "${out}/build.log" 2>&1 || { tail -30 "${out}/build.log"; exit 1; }

hex() { printf '%s' "$1" | od -An -tx1 | tr -d ' \n'; }
p="$(hex $'\n? ')"
{
  [ -z "${load}" ] || echo "${p} $(hex $'l\r')"
  echo "${p} $(hex "(le)10.0.9.1:${name}"$'\r')"
} > "${out}/serin.txt"
stop="${text}"; [ -z "${load}" ] || stop="Start address"
size="$(stat -c %s "${file}")"

"${here}/obj_dir/tb_core" +rom="${roms}/boot0.rom" +rom1="${roms}/boot1.rom" +nocard +lance +speed=3 +maxcyc=200000000 \
  +netpeer="${out}/srv" +netlog="${out}/net.pcap" +serin="${out}/serin.txt" \
  +landma="${out}/landma.txt" "+stopstr=${stop}" \
  +memdump="${out}/rxbuf.bin" +memfrom=140000 +memlen="${size}" > "${out}/run.log" 2>&1

console="$(grep '^SCC B' "${out}/run.log" | sed -E "s/^[^']*'(.*)'$/\1/" | tr -d '\n' |
           sed 's/\\x0d//g; s/\\x0a/\n/g')"
echo "${console}" > "${out}/console.txt"
grep '^NETPEER' "${out}/run.log" | tail -1
ok=1
grep -q "^stop: \"${stop}\"" "${out}/run.log" || { echo "netboot: no \"${stop}\""; ok=; }
grep -q "^NETPEER sent \"${name}\": ${size} bytes" "${out}/run.log" || { echo "netboot: not all ACKed"; ok=; }
if grep -q '^NETPEER bad frame' "${out}/run.log"; then grep '^NETPEER bad frame' "${out}/run.log" | sort | uniq -c; ok=; fi
if [ -n "${load}" ]; then
  cmp -s "${file}" "${out}/rxbuf.bin" || { echo "netboot: receive buffer differs from ${name}"; ok=; }
fi
if [ -z "${ok}" ]; then tail -20 "${out}/console.txt"; echo "netboot: FAIL"; exit 1; fi
echo "netboot: PASS, ${name} (${size} bytes) $([ -n "${load}" ] && echo loaded || echo booted)," \
  "$(grep -o '^stop: .*' "${out}/run.log")"
