#!/usr/bin/env bash
# Build the core's ROM files from your C900 ROM dumps.
#   boot0.rom (ioctl index 0): the boot ROM
#     32 KB, a 23128 pair: 0x0000-0x3FFF U17 (D15:D8), 0x4000-0x7FFF U18 (D7:D0)
#     64 KB, a 27256 pair (u17_32k u18_32k given): U17, then U18
#   boot1.rom (index 0x40): the peripheral ROMs, 16 KB
#     0x0000-0x1FFF  floppy controller 6508 (U203 2764)
#     0x2000-0x27FF  hard disk card 8049 (U10)
#     0x2800-0x2FFF  keyboard 6500/1
#     0x3000-0x3FFF  LR character ROM (U2 TMS2532)
#   scripts/make_boot_rom.sh <rom_dir> [out_dir] [u17_32k u18_32k]
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [ $# -lt 1 ] || [ ! -d "$1" ]; then
  echo "usage: $0 <rom_dir> [out_dir] [u17_32k u18_32k]" >&2
  echo "rom_dir: your C900 ROM dumps (not in this repo): new/*.bin, wdc_MCU_U10.bin, keyboard-r2.3-25.04.84.bin" >&2
  exit 2
fi
fw="$1"
out="${2:-${here}}"
mkdir -p "${out}"

# cat_parts <out> <path:size>...
cat_parts() {
  local o=$1 p f n size; shift
  : > "${o}.tmp"
  for p in "$@"; do
    f="${p%:*}"; n="${p##*:}"
    [ -f "${f}" ] || { echo "ERROR: missing ${f}" >&2; rm -f "${o}.tmp"; exit 1; }
    size="$(stat -c %s "${f}")"
    if [ "${size}" != "${n}" ]; then
      echo "ERROR: ${f} is ${size} bytes, expected ${n}" >&2; rm -f "${o}.tmp"; exit 1
    fi
    cat "${f}" >> "${o}.tmp"
  done
  mv "${o}.tmp" "${o}"
  echo "wrote ${o} ($(stat -c %s "${o}") bytes)"
}

if [ $# -ge 4 ]; then
  cat_parts "${out}/boot0.rom" "$3:32768" "$4:32768"
else
  cat_parts "${out}/boot0.rom" \
    "${fw}/new/C900 Boot-H V1.0 U17 27128 c3aa7fc1.bin:16384" \
    "${fw}/new/C900 Boot-L V1.0 U18 27128 0aa39272.bin:16384"
fi
cat_parts "${out}/boot1.rom" \
  "${fw}/new/C900 Z8000 Fl.Cont. S41 6-20-85 U203 2764 ec245721.bin:8192" \
  "${fw}/wdc_MCU_U10.bin:2048" \
  "${fw}/keyboard-r2.3-25.04.84.bin:2048" \
  "${fw}/new/C900 380217-01 R.3 PC CHAR U2 TMS2532 64cb4171.bin:4096"
